defmodule MPI.Deduplication.Match do
  @moduledoc false

  require Logger

  import Ecto.Query

  alias MPI.Repo
  alias MPI.Person
  alias MPI.MergeCandidate
  alias Ecto.UUID
  alias Confex.Resolver
  alias Ecto.Multi
  import MPI.AuditLogs, only: [create_audit_logs: 1]

  use Confex, otp_app: :mpi

  def run do
    Logger.info("Starting to look for duplicates...")
    config = config()

    depth = -config[:depth]
    deduplication_score = String.to_float(config[:score])
    comparison_fields = config[:fields]

    candidates_query =
      from p in Person,
        left_join: mc in MergeCandidate, on: mc.person_id == p.id,
        where: p.inserted_at >= datetime_add(^DateTime.utc_now(), ^depth, "day"),
        where: is_nil(mc.id),
        order_by: [desc: :inserted_at]

    persons_query =
      from p in Person,
        left_join: mc in MergeCandidate, on: mc.person_id == p.id,
        where: is_nil(mc.id),
        order_by: [desc: :inserted_at]

    candidates = Repo.all(candidates_query)
    persons = Repo.all(persons_query)

    pairs = find_duplicates candidates, persons, fn candidate, person ->
      match_score(candidate, person, comparison_fields) >= deduplication_score
    end

    if length(pairs) > 0 do
      short_pairs = Enum.map(pairs, &{elem(&1, 0).id, elem(&1, 0).id})
      Logger.info(
        "Found duplicates. Will insert the following {master_person_id, person_id} pairs: #{inspect short_pairs}"
      )

      merge_candidates =
        Enum.map pairs, fn {master_person, person} ->
          %{
            id: UUID.generate(),
            master_person_id: master_person.id,
            person_id: person.id,
            status: "NEW",
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        end

      system_user_id = Confex.fetch_env!(:mpi, :system_user)

      {:ok, _} = Multi.new()
        |> Multi.insert_all(:insert_candidates, MergeCandidate, merge_candidates, returning: true)
        |> Multi.run(:log_inserts, &log_insert(&1.insert_candidates, system_user_id))
        |> Repo.transaction()

      Enum.each config[:subscribers], fn subscriber ->
        url = Resolver.resolve!(subscriber)

        HTTPoison.post!(url, "", [{"Content-Type", "application/json"}])
      end
    else
      Logger.info("Found no duplicates.")
    end
  end

  def find_duplicates(candidates, persons, comparison_function) do
    candidate_is_duplicate? = fn person, acc ->
      Enum.any? acc, fn {_master_person, dup_person} -> dup_person == person end
    end

    pair_already_exists? = fn person1, person2, acc ->
      Enum.any? acc, &(&1 == {person1, person2})
    end

    Enum.reduce candidates, [], fn candidate, acc ->
      matching_persons =
        persons
        |> Enum.reject(fn person ->
             person == candidate ||
             candidate_is_duplicate?.(person, acc) ||
             pair_already_exists?.(person, candidate, acc)
           end)
        |> Enum.filter(fn person -> comparison_function.(candidate, person) end)
        |> Enum.map(fn person -> {candidate, person} end)

      matching_persons ++ acc
    end
  end

  def match_score(candidate, person, comparison_fields) do
    matched? = fn field_name, candidate_field, person_field ->
      case field_name do
        :documents ->
          find_passport = &(&1["type"] == "PASSPORT")

          passport1 = Enum.find(candidate_field, find_passport)
          passport2 = Enum.find(person_field, find_passport)

          if passport1 == passport2, do: :match, else: :no_match
        :phones ->
          check_phones(candidate_field, person_field)
        _ ->
          if candidate_field == person_field, do: :match, else: :no_match
      end
    end

    result =
      Enum.reduce comparison_fields, 0.0, fn {field_name, coeficients}, score ->
        candidate_field = Map.get(candidate, field_name)
        person_field = Map.get(person, field_name)

        score + coeficients[matched?.(field_name, candidate_field, person_field)]
      end

    Float.round(result, 2)
  end

  defp check_phones(candidate_field, person_field) when is_list(candidate_field) and is_list(person_field) do
    common_phones =
      for phone1 <- candidate_field,
          phone2 <- person_field,
          phone1["number"] == phone2["number"],
      do: true
    if List.first(common_phones), do: :match, else: :no_match
  end
  defp check_phones(nil, nil), do: :match
  defp check_phones(field, field), do: :match
  defp check_phones(_, _), do: :no_match

  defp log_insert({_, merge_candidates}, system_user_id) do
    changes =
      Enum.map(merge_candidates, fn mc ->
        %{
            actor_id: system_user_id,
            resource: "merge_candidates",
            resource_id: mc.id,
            changeset: sanitize_changeset(mc)
        }
      end)

    create_audit_logs(changes)
    {:ok, changes}
  end

  defp sanitize_changeset(merge_candidate) do
    merge_candidate
    |> Map.from_struct()
    |> Map.drop([:__meta__, :inserted_at, :updated_at, :master_person, :person])
  end
end
