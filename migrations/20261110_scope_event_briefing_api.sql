begin;
grant usage on schema mama_briefing to service_role;

alter function public.mama_briefing_receive(uuid,text,jsonb,text[]) set schema mama_briefing;
alter function mama_briefing.mama_briefing_receive(uuid,text,jsonb,text[]) security definer;

create function public.mama_briefing_receive(p_token uuid,p_action text,p_answers jsonb default null,
  p_photos text[] default '{}') returns boolean
language sql security invoker set search_path = '' as $$
  select mama_briefing.mama_briefing_receive(p_token,p_action,p_answers,p_photos)
$$;

create function mama_briefing.read_event(p_token uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'event_id',b.event_id,'closed_on',b.closed_on,'briefing_due',b.briefing_due,
    'promised_due',b.promised_due,'package_name',b.package_name,'includes_invite',b.includes_invite,
    'items',b.items,'accepted_at',b.accepted_at,'submitted_at',b.submitted_at,'photos',b.photos,
    'event_type',e.event_type
  )
  from public.event_briefings b join public.events e on e.id = b.event_id and e.company_id = b.company_id
  where b.token = p_token
$$;

create function public.mama_briefing_read(p_token uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select mama_briefing.read_event(p_token)
$$;

revoke execute on function public.mama_briefing_receive(uuid,text,jsonb,text[]),
  public.mama_briefing_read(uuid),mama_briefing.read_event(uuid) from public, anon, authenticated;
grant execute on function public.mama_briefing_receive(uuid,text,jsonb,text[]),
  public.mama_briefing_read(uuid),mama_briefing.read_event(uuid) to service_role;

notify pgrst,'reload schema';
commit;
