-- Diagnóstico complementar de segurança, SOMENTE LEITURA.
-- Verifica RLS, constraints e políticas de inserção/atualização.
select c.relname as tabela,c.relrowsecurity as rls_ativo,c.relforcerowsecurity as rls_forcado
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in
('clients','client_children','events','financial_entries','sales','sale_installments','manager_delete_audit')
order by c.relname;

select tablename,policyname,cmd,qual,with_check
from pg_policies
where schemaname='public' and tablename in
('clients','client_children','events','financial_entries','sales','sale_installments')
and cmd in ('INSERT','UPDATE','ALL')
order by tablename,cmd,policyname;

-- Diagnóstico das relações que podem bloquear exclusões.
select conrelid::regclass as tabela,conname as restricao,
confrelid::regclass as tabela_referenciada,
pg_get_constraintdef(oid) as definicao
from pg_constraint
where contype='f' and connamespace='public'::regnamespace
and (conrelid in ('public.clients'::regclass,'public.client_children'::regclass,'public.events'::regclass,'public.sales'::regclass,'public.sale_installments'::regclass)
or confrelid in ('public.clients'::regclass,'public.client_children'::regclass,'public.events'::regclass,'public.sales'::regclass,'public.sale_installments'::regclass))
order by conrelid::regclass::text,conname;
