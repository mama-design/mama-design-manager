begin;
create table public.event_production (
 event_id uuid primary key references public.events(id) on delete cascade,
 company_id uuid not null references public.companies(id) on delete cascade,
 stage text not null default 'queue' check (stage in ('queue','creating','review','adjustments','done')),
 notes text not null default '' check (length(notes)<=5000),
 updated_at timestamptz not null default now()
);
create index event_production_company_idx on public.event_production(company_id);
alter table public.event_production enable row level security;
revoke all on public.event_production from public,anon;
grant select,insert,update on public.event_production to authenticated;
create policy production_read on public.event_production for select to authenticated
 using (public.has_member_permission(company_id,'events','view'));
create policy production_insert on public.event_production for insert to authenticated
 with check (public.has_member_permission(company_id,'events','edit') and exists (
  select 1 from public.events e where e.id=event_id and e.company_id=event_production.company_id
 ));
create policy production_update on public.event_production for update to authenticated
 using (public.has_member_permission(company_id,'events','edit'))
 with check (public.has_member_permission(company_id,'events','edit') and exists (
  select 1 from public.events e where e.id=event_id and e.company_id=event_production.company_id
 ));
create function public.mama_production_save(p_event uuid,p_stage text default null,p_notes text default null)
returns void language plpgsql security invoker set search_path='' as $$
begin
 insert into public.event_production(event_id,company_id,stage,notes)
 select e.id,e.company_id,coalesce(p_stage,'queue'),coalesce(p_notes,'') from public.events e where e.id=p_event
 on conflict(event_id) do update set
  stage=coalesce(p_stage,event_production.stage),notes=coalesce(p_notes,event_production.notes),updated_at=now();
 if not found then raise exception 'Evento indisponível para edição.'; end if;
 if p_stage='review' and exists(select 1 from public.event_briefings where event_id=p_event and submitted_at is not null and preview_sent_at is null) then
  perform public.mama_briefing_manage(p_event,'sent');
 end if;
end $$;
revoke execute on function public.mama_production_save(uuid,text,text) from public,anon;
grant execute on function public.mama_production_save(uuid,text,text) to authenticated;

create function mama_briefing.delete_event(p_event uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare company uuid;
begin
 select company_id into company from public.events where id=p_event for update;
 if not found then return false; end if;
 if auth.uid() is null or not public.has_member_permission(company,'events','delete') then
  raise exception 'Você não tem permissão para excluir este evento.';
 end if;
 if exists(select 1 from public.sales where event_id=p_event) then
  raise exception 'Este evento possui venda vinculada. Resolva o vínculo no Comercial antes de excluir.';
 end if;
 delete from public.events where id=p_event;
 return true;
end $$;
create function public.mama_event_delete(p_event uuid) returns boolean
language sql security invoker set search_path='' as $$
 select mama_briefing.delete_event(p_event)
$$;
revoke execute on function mama_briefing.delete_event(uuid),public.mama_event_delete(uuid) from public,anon;
grant execute on function mama_briefing.delete_event(uuid),public.mama_event_delete(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
