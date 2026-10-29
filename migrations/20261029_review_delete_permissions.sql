-- Diagnóstico somente leitura: políticas de exclusão e histórico.
-- Não modifica dados nem permissões.
select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname='public'
  and tablename in ('clients','client_children','events','sales','sale_installments','financial_entries','manager_delete_audit')
order by tablename, cmd, policyname;

select table_name, privilege_type, grantee
from information_schema.role_table_grants
where table_schema='public'
  and table_name in ('clients','client_children','events','sales','sale_installments','financial_entries','manager_delete_audit')
  and grantee in ('anon','authenticated')
order by table_name,grantee,privilege_type;
