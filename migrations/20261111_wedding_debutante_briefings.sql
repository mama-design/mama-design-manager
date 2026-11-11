begin;
CREATE OR REPLACE FUNCTION mama_briefing.create_event(p_company uuid, p_client uuid, p_package uuid, p_type text, p_closed date, p_request uuid, p_override date, p_invite boolean, p_items text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if p_request is null or p_type not in ('Aniversário infantil','Chá de bebê','Social','Casamento','15 anos') or p_type is null
    or p_closed is null or p_closed > (now() at time zone 'America/Sao_Paulo')::date
    or p_override < p_closed or length(coalesce(p_items,'')) > 1500 then
    raise exception 'Confira o tipo do evento e as datas.';
  end if;
  select * into strict client_row from public.clients where id = p_client and company_id = p_company;
  select * into package_row from public.service_packages
    where id = p_package and company_id = p_company and active
      and case p_type
        when 'Casamento' then lower(trim(event_type)) = 'casamento'
        when '15 anos' then lower(trim(event_type)) in ('debutante','15 anos')
        else lower(coalesce(event_type,'')) ~ '(infantil|social)'
      end;
  if not found then raise exception 'Selecione um pacote compatível com o tipo de evento.'; end if;
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
end $function$;
commit;
