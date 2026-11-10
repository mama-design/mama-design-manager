begin;

alter table public.events alter column event_date drop not null;
alter table public.clients add column briefing_business_days smallint not null default 10
  check (briefing_business_days in (7, 10));
alter table public.service_packages
  add column briefing_invite boolean,
  add column briefing_items text not null default '' check (length(briefing_items) <= 1500);

create table public.event_briefings (
  event_id uuid primary key references public.events(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  package_id uuid references public.service_packages(id) on delete set null,
  package_name text not null,
  token uuid not null unique default gen_random_uuid(),
  closed_on date not null,
  briefing_due date not null,
  promised_due date not null,
  internal_due date not null,
  includes_invite boolean not null,
  items text not null default '',
  accepted_at timestamptz,
  accepted_dates jsonb,
  submitted_at timestamptz,
  preview_sent_at timestamptz,
  answers jsonb,
  photos text[] not null default '{}'
);
create index event_briefings_company_due_idx on public.event_briefings(company_id, internal_due);
create index event_briefings_package_idx on public.event_briefings(package_id);
alter table public.event_briefings enable row level security;
revoke all on public.event_briefings from public, anon, authenticated;
grant select (event_id, company_id, package_id, package_name, closed_on, briefing_due, promised_due,
  internal_due, includes_invite, items, accepted_at, accepted_dates, submitted_at, preview_sent_at, answers, photos)
  on public.event_briefings to authenticated;
grant all on public.event_briefings to service_role;
create policy "Equipe autorizada consulta briefings" on public.event_briefings for select to authenticated
  using (public.has_member_permission(company_id, 'events', 'view'));

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('mama-briefing-photos', 'mama-briefing-photos', false, 6291456,
  array['image/jpeg','image/png','image/webp','image/heic','image/heif']);
create policy "Equipe autorizada lê fotos do briefing" on storage.objects for select to authenticated
  using (bucket_id = 'mama-briefing-photos' and exists (
    select 1 from public.event_briefings b
    where b.event_id::text = (storage.foldername(name))[1] and b.submitted_at is not null
      and storage.objects.name = any(b.photos)
  ));

create schema mama_briefing;
revoke all on schema mama_briefing from public;
grant usage on schema mama_briefing to authenticated;

create function mama_briefing.business_day(p_date date, p_days int) returns date
language plpgsql immutable strict set search_path = '' as $$
begin
  while p_days <> 0 loop
    p_date := p_date + sign(p_days)::int;
    if extract(isodow from p_date) < 6 then p_days := p_days - sign(p_days)::int; end if;
  end loop;
  return p_date;
end $$;
revoke execute on function mama_briefing.business_day(date,int) from public;

create function mama_briefing.create_event(
  p_company uuid, p_client uuid, p_package uuid, p_type text,
  p_closed date, p_request uuid, p_override date, p_invite boolean, p_items text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  client_row public.clients;
  package_row public.service_packages;
  new_event uuid;
  link_token uuid;
  promised date;
  internal_date date;
begin
  if auth.uid() is null or not public.has_member_permission(p_company,'events','create')
    or not public.has_member_permission(p_company,'clients','view')
    or not public.has_member_permission(p_company,'packages','view') then
    raise exception 'Sem permissão para criar briefing.';
  end if;
  if p_request is null or p_type not in ('Aniversário infantil','Chá de bebê','Social') or p_type is null
    or p_closed is null or p_closed > (now() at time zone 'America/Sao_Paulo')::date
    or p_override < p_closed or length(coalesce(p_items,'')) > 1500 then
    raise exception 'Confira o tipo do evento e as datas.';
  end if;
  select * into strict client_row from public.clients where id = p_client and company_id = p_company;
  select * into strict package_row from public.service_packages
    where id = p_package and company_id = p_company and active
      and lower(coalesce(event_type,'')) ~ '(infantil|social)';
  if coalesce(p_invite, package_row.briefing_invite) is null then
    raise exception 'Informe se o pacote inclui convite.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select b.token into link_token from public.event_briefings b join public.events e on e.id = b.event_id
    where b.event_id = p_request and b.company_id = p_company and e.client_id = p_client;
  if found then return jsonb_build_object('event_id',p_request,'token',link_token); end if;
  promised := coalesce(p_override, mama_briefing.business_day(p_closed,client_row.briefing_business_days));
  internal_date := greatest(p_closed, mama_briefing.business_day(promised,-2));
  insert into public.events(id, company_id, client_id, title, event_type, identity_due_date)
    values (p_request,p_company,p_client,p_type || ' · ' || client_row.full_name,p_type,promised)
    returning id into new_event;
  insert into public.event_briefings(event_id,company_id,package_id,package_name,closed_on,
    briefing_due,promised_due,internal_due,includes_invite,items)
    values(new_event,p_company,p_package,package_row.name,p_closed,
      least(mama_briefing.business_day(p_closed,3),promised),promised,internal_date,
      coalesce(p_invite,package_row.briefing_invite),coalesce(p_items,package_row.briefing_items))
    returning token into link_token;
  return jsonb_build_object('event_id',new_event,'token',link_token);
end $$;

create function public.mama_briefing_create(
  p_company uuid, p_client uuid, p_package uuid, p_type text, p_closed date, p_request uuid,
  p_override date default null, p_invite boolean default null, p_items text default null
) returns jsonb language sql security invoker set search_path = '' as $$
  select mama_briefing.create_event(p_company,p_client,p_package,p_type,p_closed,p_request,p_override,p_invite,p_items)
$$;

create function mama_briefing.manage_event(p_event uuid,p_action text,p_date date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare b public.event_briefings;
begin
  select * into strict b from public.event_briefings where event_id = p_event for update;
  if auth.uid() is null or not public.has_member_permission(b.company_id,'events','edit') then
    raise exception 'Sem permissão para alterar briefing.';
  end if;
  if p_action = 'link' then return b.token; end if;
  if p_action = 'renew' and b.submitted_at is null then
    update public.event_briefings set token = gen_random_uuid(), accepted_at = null, accepted_dates = null
      where event_id = p_event returning token into b.token;
    return b.token;
  end if;
  if p_action = 'deadline' and p_date >= b.closed_on and b.preview_sent_at is null then
    update public.events set identity_due_date = p_date where id = p_event;
    update public.event_briefings set promised_due = p_date,
      internal_due = greatest(closed_on,mama_briefing.business_day(p_date,-2))
      where event_id = p_event;
    return null;
  end if;
  if p_action = 'sent' and b.submitted_at is not null then
    update public.event_briefings set preview_sent_at = coalesce(preview_sent_at,now()) where event_id = p_event;
    return null;
  end if;
  raise exception 'Ação indisponível para este briefing.';
end $$;

create function public.mama_briefing_manage(p_event uuid,p_action text,p_date date default null)
returns uuid language sql security invoker set search_path = '' as $$
  select mama_briefing.manage_event(p_event,p_action,p_date)
$$;

revoke execute on function mama_briefing.create_event(uuid,uuid,uuid,text,date,uuid,date,boolean,text),
  mama_briefing.manage_event(uuid,text,date),
  public.mama_briefing_create(uuid,uuid,uuid,text,date,uuid,date,boolean,text),
  public.mama_briefing_manage(uuid,text,date) from public, anon;
grant execute on function mama_briefing.create_event(uuid,uuid,uuid,text,date,uuid,date,boolean,text),
  mama_briefing.manage_event(uuid,text,date),
  public.mama_briefing_create(uuid,uuid,uuid,text,date,uuid,date,boolean,text),
  public.mama_briefing_manage(uuid,text,date) to authenticated;

create function public.mama_briefing_receive(p_token uuid,p_action text,p_answers jsonb default null,
  p_photos text[] default '{}') returns boolean
language plpgsql security invoker set search_path = '' as $$
declare b public.event_briefings;
declare event_date_value date;
declare start_value time;
declare end_value time;
begin
  select * into b from public.event_briefings where token = p_token for update;
  if not found then return false; end if;
  if b.submitted_at is not null then return false; end if;
  if p_action = 'accept' then
    if b.accepted_at is null and (p_answers->>'briefing_due' is distinct from b.briefing_due::text
      or p_answers->>'promised_due' is distinct from b.promised_due::text) then return false; end if;
    update public.event_briefings set accepted_at = coalesce(accepted_at,now()),
      accepted_dates = coalesce(accepted_dates,jsonb_build_object('briefing_due',briefing_due,'promised_due',promised_due))
      where event_id = b.event_id;
    return true;
  end if;
  if p_action <> 'submit' or b.accepted_at is null or p_answers is null
    or coalesce(length(trim(p_answers->>'title')),0) not between 1 and 200
    or length(p_answers::text) > 24000 or coalesce(cardinality(p_photos),0) > 8 then return false; end if;
  event_date_value := (p_answers->>'event_date')::date;
  start_value := nullif(p_answers->>'start_time','')::time;
  end_value := nullif(p_answers->>'end_time','')::time;
  if event_date_value is null or event_date_value < b.closed_on
    or (end_value is not null and (start_value is null or end_value <= start_value))
    or exists (select 1 from unnest(p_photos) as photo(path)
      where photo.path is null or split_part(photo.path,'/',1) <> b.event_id::text or not exists (
        select 1 from storage.objects o where o.bucket_id = 'mama-briefing-photos'
          and o.name = photo.path
      )) then return false; end if;
  update public.events set title = trim(p_answers->>'title'), event_date = event_date_value,
    start_time = start_value, end_time = end_value, venue_name = nullif(p_answers->>'venue',''),
    venue_address = nullif(p_answers->>'address',''), identity_due_date = b.promised_due,
    updated_at = now() where id = b.event_id and company_id = b.company_id;
  if not found then return false; end if;
  update public.event_briefings set answers = p_answers, photos = coalesce(p_photos,'{}'), submitted_at = now()
    where event_id = b.event_id;
  return true;
end $$;
revoke execute on function public.mama_briefing_receive(uuid,text,jsonb,text[]) from public, anon, authenticated;
grant execute on function public.mama_briefing_receive(uuid,text,jsonb,text[]) to service_role;

notify pgrst, 'reload schema';
commit;
