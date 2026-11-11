begin;
alter table public.sales add column briefing_generated boolean not null default false;
create unique index sales_one_generated_briefing on public.sales(event_id) where briefing_generated and event_id is not null;

create function mama_briefing.lock_open_months(p_company uuid,p_dates date[]) returns void
language plpgsql security invoker set search_path='' as $$
declare month_date date;
begin
 for month_date in select distinct date_trunc('month',d)::date from unnest(p_dates) d where d is not null order by 1 loop
  perform pg_advisory_xact_lock(hashtextextended(p_company::text||month_date::text,0));
  if exists(select 1 from public.financial_month_closings where company_id=p_company and month_start=month_date) then
   raise exception 'O mês % está fechado. Reabra-o antes de alterar estes valores.',to_char(month_date,'MM/YYYY');
  end if;
 end loop;
end $$;
revoke all on function mama_briefing.lock_open_months(uuid,date[]) from public,anon,authenticated;

create function mama_briefing.lock_closing() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.company_id::text||new.month_start::text,0));
 return new;
end $$;
revoke all on function mama_briefing.lock_closing() from public,anon,authenticated;
create trigger serialize_sale_month_closing before insert on public.financial_month_closings
 for each row execute function mama_briefing.lock_closing();

create function mama_briefing.ensure_briefing_sale(p_event uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare e public.events; b public.event_briefings; p public.service_packages; existing uuid; sale uuid;
begin
 select * into strict e from public.events where id=p_event for update;
 if auth.uid() is null or not public.has_member_permission(e.company_id,'sales','create') then
  raise exception 'Seu perfil precisa de permissão para criar vendas ao gerar um briefing.';
 end if;
 select id into existing from public.sales where event_id=e.id order by created_at limit 1;
 if found then return existing; end if;
 select * into strict b from public.event_briefings where event_id=e.id;
 select * into strict p from public.service_packages where id=b.package_id and company_id=e.company_id;
 if p.price is null or p.price<=0 then raise exception 'Defina um valor maior que zero no pacote antes de gerar a venda.'; end if;
 perform mama_briefing.lock_open_months(e.company_id,array[b.closed_on]);
 insert into public.sales(company_id,client_id,event_id,package_id,description,sale_date,total_amount,status,created_by,briefing_generated)
 values(e.company_id,e.client_id,e.id,p.id,p.name,b.closed_on,p.price,'approved',auth.uid(),true)
 returning id into sale;
 insert into public.sale_installments(sale_id,installment_number,due_date,amount,paid_amount)
 values(sale,1,b.closed_on,p.price,0);
 return sale;
end $$;
revoke all on function mama_briefing.ensure_briefing_sale(uuid) from public,anon;
grant execute on function mama_briefing.ensure_briefing_sale(uuid) to authenticated;

create function public.mama_briefing_sale(p_event uuid) returns uuid
language sql security invoker set search_path='' as $$
 select mama_briefing.ensure_briefing_sale(p_event)
$$;
revoke all on function public.mama_briefing_sale(uuid) from public,anon;
grant execute on function public.mama_briefing_sale(uuid) to authenticated;

create function mama_briefing.on_briefing_sale() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform mama_briefing.ensure_briefing_sale(new.event_id);
 return new;
end $$;
revoke all on function mama_briefing.on_briefing_sale() from public,anon,authenticated;
create trigger generate_briefing_sale after insert on public.event_briefings
 for each row execute function mama_briefing.on_briefing_sale();

create function mama_briefing.receipt_update(p_installment uuid,p_amount numeric,p_paid numeric,p_due date,p_paid_at date,
 p_expected_amount numeric,p_expected_paid numeric,p_expected_due date,p_expected_paid_at date)
returns void language plpgsql security definer set search_path='' as $$
declare s public.sales; i public.sale_installments;
begin
 select sale_id into i.sale_id from public.sale_installments where id=p_installment;
 if not found then raise exception 'Recebimento não encontrado.'; end if;
 select * into strict s from public.sales where id=i.sale_id for update;
 if auth.uid() is null or not public.has_member_permission(s.company_id,'finance','edit') then raise exception 'Sem permissão para editar recebimentos.'; end if;
 if s.status='cancelled' then raise exception 'Esta venda está cancelada.'; end if;
 select * into strict i from public.sale_installments where id=p_installment for update;
 if i.amount is distinct from p_expected_amount or i.paid_amount is distinct from p_expected_paid
  or i.due_date is distinct from p_expected_due or i.paid_at is distinct from p_expected_paid_at then
  raise exception 'O recebimento foi alterado. Atualize a lista antes de tentar novamente.';
 end if;
 if p_amount is null or p_amount<=0 or p_amount::text in ('NaN','Infinity','-Infinity') or p_paid is null
  or p_paid::text in ('NaN','Infinity','-Infinity') or p_paid<0 or p_paid>p_amount or p_due is null
  or (p_paid>0 and p_paid_at is null) then raise exception 'Confira valor, vencimento e data do recebimento.'; end if;
 perform mama_briefing.lock_open_months(s.company_id,array[i.due_date,i.paid_at,p_due,case when p_paid>0 then p_paid_at end]);
 update public.sale_installments set amount=p_amount,paid_amount=p_paid,due_date=p_due,paid_at=case when p_paid>0 then p_paid_at end where id=i.id;
 update public.sales set total_amount=(select sum(amount) from public.sale_installments where sale_id=s.id),updated_at=now() where id=s.id;
end $$;
revoke all on function mama_briefing.receipt_update(uuid,numeric,numeric,date,date,numeric,numeric,date,date) from public,anon;
grant execute on function mama_briefing.receipt_update(uuid,numeric,numeric,date,date,numeric,numeric,date,date) to authenticated;
create function public.mama_receipt_update(p_installment uuid,p_amount numeric,p_paid numeric,p_due date,p_paid_at date,
 p_expected_amount numeric,p_expected_paid numeric,p_expected_due date,p_expected_paid_at date)
returns void language sql security invoker set search_path='' as $$
 select mama_briefing.receipt_update(p_installment,p_amount,p_paid,p_due,p_paid_at,p_expected_amount,p_expected_paid,p_expected_due,p_expected_paid_at)
$$;
revoke all on function public.mama_receipt_update(uuid,numeric,numeric,date,date,numeric,numeric,date,date) from public,anon;
grant execute on function public.mama_receipt_update(uuid,numeric,numeric,date,date,numeric,numeric,date,date) to authenticated;

create function mama_briefing.sale_save(p_id uuid,p_company uuid,p_client uuid,p_event uuid,p_package uuid,
 p_description text,p_sale_date date,p_total numeric,p_due date,p_paid numeric,p_paid_at date,p_notes text,p_expected_updated timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare s public.sales; sale uuid; count_rows int; old_amount numeric; old_paid numeric; old_due date; old_dates date[];
begin
 if auth.uid() is null or not public.has_member_permission(p_company,'sales',case when p_id is null then 'create' else 'edit' end) then raise exception 'Sem permissão para salvar esta venda.'; end if;
 if p_total is null or p_total<=0 or p_total::text in ('NaN','Infinity','-Infinity') or p_paid is null
  or p_paid::text in ('NaN','Infinity','-Infinity') or p_paid<0 or p_paid>p_total or p_due is null or p_sale_date is null
  or (p_paid>0 and p_paid_at is null) or coalesce(length(trim(p_description)),0) not between 1 and 300 then raise exception 'Confira a descrição, os valores e as datas.'; end if;
 if not exists(select 1 from public.clients where id=p_client and company_id=p_company)
  or (p_event is not null and not exists(select 1 from public.events where id=p_event and company_id=p_company and client_id=p_client))
  or (p_package is not null and not exists(select 1 from public.service_packages where id=p_package and company_id=p_company)) then raise exception 'Confira os vínculos da venda.'; end if;
 if p_event is not null then
  perform 1 from public.events where id=p_event for update;
  if exists(select 1 from public.sales where event_id=p_event and id<>coalesce(p_id,'00000000-0000-0000-0000-000000000000') and status<>'cancelled') then
   raise exception 'Este evento já possui venda. Edite a venda vinculada para evitar duplicidade.';
  end if;
 end if;
 if p_id is not null then
  select * into strict s from public.sales where id=p_id and company_id=p_company for update;
  if s.updated_at is distinct from p_expected_updated then raise exception 'A venda foi alterada. Atualize a lista e tente novamente.'; end if;
  if s.briefing_generated and (s.event_id is distinct from p_event or s.client_id is distinct from p_client or s.package_id is distinct from p_package) then raise exception 'Mantenha a cliente, o evento e o pacote vinculados ao briefing.'; end if;
  if s.status='cancelled' then raise exception 'Esta venda está cancelada.'; end if;
  perform 1 from public.sale_installments where sale_id=s.id for update;
  select count(*),coalesce(sum(amount),0),coalesce(sum(paid_amount),0),min(due_date),array_agg(due_date)||array_agg(paid_at)
  into count_rows,old_amount,old_paid,old_due,old_dates from public.sale_installments where sale_id=s.id;
  if count_rows>1 and (old_amount<>p_total or old_paid<>p_paid) then raise exception 'Esta venda possui parcelas. Edite cada recebimento no Financeiro.'; end if;
 else count_rows:=0;
 end if;
 perform mama_briefing.lock_open_months(p_company,coalesce(old_dates,'{}')||array[p_sale_date,s.sale_date,p_due,case when p_paid>0 then p_paid_at end]);
 if p_id is null then
  insert into public.sales(id,company_id,client_id,event_id,package_id,description,sale_date,total_amount,status,notes,created_by)
  values(gen_random_uuid(),p_company,p_client,p_event,p_package,trim(p_description),p_sale_date,p_total,'approved',nullif(p_notes,''),auth.uid()) returning id into sale;
 else
  sale:=p_id;
  update public.sales set client_id=p_client,event_id=p_event,package_id=p_package,description=trim(p_description),
   sale_date=p_sale_date,total_amount=p_total,notes=nullif(p_notes,''),updated_at=now() where id=p_id;
 end if;
 if count_rows=0 then
  insert into public.sale_installments(sale_id,installment_number,due_date,amount,paid_amount,paid_at)
  values(sale,1,p_due,p_total,p_paid,case when p_paid>0 then p_paid_at end);
 elsif count_rows=1 then
  update public.sale_installments set amount=p_total,paid_amount=p_paid,due_date=p_due,paid_at=case when p_paid>0 then p_paid_at end where sale_id=sale;
 end if;
 return sale;
end $$;
revoke all on function mama_briefing.sale_save(uuid,uuid,uuid,uuid,uuid,text,date,numeric,date,numeric,date,text,timestamptz) from public,anon;
grant execute on function mama_briefing.sale_save(uuid,uuid,uuid,uuid,uuid,text,date,numeric,date,numeric,date,text,timestamptz) to authenticated;
create function public.mama_sale_save(p_id uuid,p_company uuid,p_client uuid,p_event uuid,p_package uuid,
 p_description text,p_sale_date date,p_total numeric,p_due date,p_paid numeric,p_paid_at date,p_notes text,p_expected_updated timestamptz)
returns uuid language sql security invoker set search_path='' as $$
 select mama_briefing.sale_save(p_id,p_company,p_client,p_event,p_package,p_description,p_sale_date,p_total,p_due,p_paid,p_paid_at,p_notes,p_expected_updated)
$$;
revoke all on function public.mama_sale_save(uuid,uuid,uuid,uuid,uuid,text,date,numeric,date,numeric,date,text,timestamptz) from public,anon;
grant execute on function public.mama_sale_save(uuid,uuid,uuid,uuid,uuid,text,date,numeric,date,numeric,date,text,timestamptz) to authenticated;

create or replace function mama_briefing.delete_event(p_event uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare company uuid; sale public.sales;
begin
 select company_id into company from public.events where id=p_event for update;
 if not found then return false; end if;
 if auth.uid() is null or not public.has_member_permission(company,'events','delete') then raise exception 'Você não tem permissão para excluir este evento.'; end if;
 for sale in select * from public.sales where event_id=p_event order by id for update loop
  perform 1 from public.sale_installments where sale_id=sale.id for update;
  if not sale.briefing_generated or exists(select 1 from public.sale_installments where sale_id=sale.id and paid_amount>0) then
   raise exception 'Este evento possui venda com recebimento ou cadastro manual. Resolva o vínculo no Comercial antes de excluir.';
  end if;
  perform mama_briefing.lock_open_months(company,array[sale.sale_date]||(select array_agg(due_date) from public.sale_installments where sale_id=sale.id));
  delete from public.sales where id=sale.id;
 end loop;
 delete from public.events where id=p_event;
 return true;
end $$;
notify pgrst,'reload schema';
commit;
