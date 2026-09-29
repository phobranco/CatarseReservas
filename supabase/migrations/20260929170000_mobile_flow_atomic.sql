create or replace function public.complete_mobile_flow_stage(
  p_reservation_id uuid,
  p_stage text,
  p_checked_item_ids uuid[] default '{}'::uuid[],
  p_issue_item_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reservation public.reservations%rowtype;
  v_total integer;
  v_checked integer;
  v_issues integer;
  v_returned integer;
  v_status public.reservation_status;
begin
  if v_actor is null then
    raise exception 'Faça login novamente para continuar.';
  end if;

  if p_stage not in ('separacao', 'checkout', 'retorno', 'checkin') then
    raise exception 'Etapa inválida.';
  end if;

  select * into v_reservation
  from public.reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'Reserva não encontrada.';
  end if;

  if v_reservation.requested_by <> v_actor
     and v_reservation.responsible_user_id <> v_actor
     and not public.is_manager() then
    raise exception 'Você não tem permissão para operar esta reserva.';
  end if;

  select count(*) into v_total
  from public.reservation_items
  where reservation_id = p_reservation_id and status <> 'cancelado';

  select count(distinct ri.id) into v_checked
  from public.reservation_items ri
  where ri.reservation_id = p_reservation_id
    and ri.status <> 'cancelado'
    and ri.id = any(coalesce(p_checked_item_ids, '{}'::uuid[]));

  select count(distinct ri.id) into v_issues
  from public.reservation_items ri
  where ri.reservation_id = p_reservation_id
    and ri.status <> 'cancelado'
    and ri.id = any(coalesce(p_issue_item_ids, '{}'::uuid[]));

  if v_total = 0 then
    raise exception 'Esta reserva não possui equipamentos ativos.';
  end if;

  if v_checked <> coalesce(cardinality(p_checked_item_ids), 0) then
    raise exception 'A seleção contém equipamentos que não pertencem à reserva.';
  end if;

  if v_issues <> coalesce(cardinality(p_issue_item_ids), 0)
     or exists (
       select 1 from unnest(coalesce(p_issue_item_ids, '{}'::uuid[])) issue_id
       where not (issue_id = any(coalesce(p_checked_item_ids, '{}'::uuid[])))
     ) then
    raise exception 'Todo problema precisa estar ligado a um equipamento recebido.';
  end if;

  if p_stage in ('separacao', 'checkout') and v_checked <> v_total then
    raise exception 'Confira todos os equipamentos antes de concluir esta etapa.';
  end if;

  if p_stage = 'separacao' then
    update public.reservation_items
       set status = 'separado'
     where reservation_id = p_reservation_id
       and status <> 'cancelado';

    insert into public.reservation_events(reservation_id, event_type, actor_id, metadata)
    select p_reservation_id, 'fluxo_separacao_concluida', v_actor,
           jsonb_build_object('checked_item_ids', to_jsonb(p_checked_item_ids))
    where not exists (
      select 1 from public.reservation_events
      where reservation_id = p_reservation_id
        and event_type = 'fluxo_separacao_concluida'
    );

  elsif p_stage = 'checkout' then
    if not exists (
      select 1 from public.reservation_events
      where reservation_id = p_reservation_id
        and event_type = 'fluxo_separacao_concluida'
    ) and exists (
      select 1 from public.reservation_items
      where reservation_id = p_reservation_id
        and status not in ('separado', 'retirado', 'devolvido', 'pendente', 'cancelado')
    ) then
      raise exception 'Conclua a separação antes do check-out.';
    end if;

    update public.reservation_items
       set status = 'retirado',
           checked_out_at = coalesce(checked_out_at, now()),
           checked_out_by = coalesce(checked_out_by, v_actor)
     where reservation_id = p_reservation_id
       and status not in ('cancelado', 'devolvido');

    update public.reservations
       set status = 'em_uso'
     where id = p_reservation_id;

    insert into public.reservation_events(reservation_id, event_type, actor_id, metadata)
    select p_reservation_id, 'fluxo_checkout_concluido', v_actor,
           jsonb_build_object('checked_item_ids', to_jsonb(p_checked_item_ids))
    where not exists (
      select 1 from public.reservation_events
      where reservation_id = p_reservation_id
        and event_type = 'fluxo_checkout_concluido'
    );

  elsif p_stage = 'retorno' then
    if not exists (
      select 1 from public.reservation_events
      where reservation_id = p_reservation_id
        and event_type = 'fluxo_checkout_concluido'
    ) and exists (
      select 1 from public.reservation_items
      where reservation_id = p_reservation_id
        and status not in ('retirado', 'devolvido', 'pendente', 'cancelado')
    ) then
      raise exception 'Conclua o check-out antes da conferência de retorno.';
    end if;

    if v_checked = v_total then
      insert into public.reservation_events(reservation_id, event_type, actor_id, metadata)
      select p_reservation_id, 'fluxo_retorno_concluido', v_actor,
             jsonb_build_object('checked_item_ids', to_jsonb(p_checked_item_ids))
      where not exists (
        select 1 from public.reservation_events
        where reservation_id = p_reservation_id
          and event_type = 'fluxo_retorno_concluido'
      );
    else
      insert into public.reservation_events(reservation_id, event_type, actor_id, metadata)
      values (
        p_reservation_id,
        'fluxo_retorno_parcial',
        v_actor,
        jsonb_build_object(
          'checked_item_ids', to_jsonb(p_checked_item_ids),
          'checked_count', v_checked,
          'total_count', v_total
        )
      );
    end if;

  elsif p_stage = 'checkin' then
    if not exists (
      select 1 from public.reservation_events
      where reservation_id = p_reservation_id
        and event_type = 'fluxo_retorno_concluido'
    ) and v_reservation.status <> 'devolucao_parcial' then
      raise exception 'Conclua a conferência de retorno antes do check-in.';
    end if;

    update public.reservation_items ri
       set status = 'devolvido',
           returned_at = coalesce(ri.returned_at, now()),
           returned_by = coalesce(ri.returned_by, v_actor),
           problem_reported = ri.id = any(coalesce(p_issue_item_ids, '{}'::uuid[])),
           return_condition = case
             when ri.id = any(coalesce(p_issue_item_ids, '{}'::uuid[])) then 'avariado'::public.asset_condition
             else coalesce(ri.return_condition, 'bom'::public.asset_condition)
           end
     where ri.reservation_id = p_reservation_id
       and ri.status <> 'cancelado'
       and ri.id = any(coalesce(p_checked_item_ids, '{}'::uuid[]));

    update public.reservation_items ri
       set status = 'pendente'
     where ri.reservation_id = p_reservation_id
       and ri.status not in ('cancelado', 'devolvido')
       and not (ri.id = any(coalesce(p_checked_item_ids, '{}'::uuid[])));

    insert into public.maintenance_cases(asset_id, opened_by, issue, status, notes)
    select ri.asset_id, v_actor, 'Problema informado no check-in da reserva',
           'aguardando_levar'::public.maintenance_status,
           'Reserva ' || p_reservation_id::text
      from public.reservation_items ri
     where ri.reservation_id = p_reservation_id
       and ri.id = any(coalesce(p_issue_item_ids, '{}'::uuid[]))
       and not exists (
         select 1 from public.maintenance_cases mc
          where mc.asset_id = ri.asset_id
            and mc.status not in ('retornado', 'cancelado')
       );

    select count(*) into v_returned
      from public.reservation_items
     where reservation_id = p_reservation_id
       and status = 'devolvido';

    if v_returned = v_total then
      update public.reservations set status = 'concluido' where id = p_reservation_id;
      insert into public.reservation_events(reservation_id, event_type, actor_id, metadata)
      select p_reservation_id, 'fluxo_checkin_concluido', v_actor,
             jsonb_build_object('checked_item_ids', to_jsonb(p_checked_item_ids), 'issue_item_ids', to_jsonb(p_issue_item_ids))
      where not exists (
        select 1 from public.reservation_events
        where reservation_id = p_reservation_id
          and event_type = 'fluxo_checkin_concluido'
      );
    else
      update public.reservations set status = 'devolucao_parcial' where id = p_reservation_id;
      insert into public.reservation_events(reservation_id, event_type, actor_id, metadata)
      values (
        p_reservation_id,
        'fluxo_checkin_parcial',
        v_actor,
        jsonb_build_object(
          'checked_item_ids', to_jsonb(p_checked_item_ids),
          'issue_item_ids', to_jsonb(p_issue_item_ids),
          'returned_count', v_returned,
          'total_count', v_total
        )
      );
    end if;
  end if;

  select status into v_status from public.reservations where id = p_reservation_id;

  return jsonb_build_object(
    'ok', true,
    'stage', p_stage,
    'reservation_status', v_status,
    'checked_count', v_checked,
    'total_count', v_total,
    'completed', case
      when p_stage in ('retorno', 'checkin') then v_checked = v_total
      else true
    end
  );
end;
$$;

revoke all on function public.complete_mobile_flow_stage(uuid, text, uuid[], uuid[]) from public;
revoke all on function public.complete_mobile_flow_stage(uuid, text, uuid[], uuid[]) from anon;
grant execute on function public.complete_mobile_flow_stage(uuid, text, uuid[], uuid[]) to authenticated;
