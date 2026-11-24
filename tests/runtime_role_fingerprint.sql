-- Canonical effective object ACL entries and role flags, never passwords/verifiers.
-- Includes public grants and all public schema relations/functions, even unrelated
-- objects, so unexpected grants do not disappear from the comparison.
SET search_path=pg_catalog;
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
WITH role_names(name) AS (VALUES ('radius_api'),('radius_runtime'),('radius_bootstrap')),
entries AS (
 SELECT jsonb_build_array('role',rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,
    rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolvaliduntil,rolconfig) AS entry
 FROM pg_roles WHERE rolname IN (SELECT name FROM role_names)
 UNION ALL
 SELECT jsonb_build_array('membership',pg_get_userbyid(roleid),pg_get_userbyid(member),
    pg_get_userbyid(grantor),admin_option,inherit_option,set_option)
 FROM pg_auth_members WHERE pg_get_userbyid(roleid) IN (SELECT name FROM role_names)
    OR pg_get_userbyid(member) IN (SELECT name FROM role_names)
 UNION ALL
 SELECT jsonb_build_array('database',d.datname,pg_get_userbyid(d.datdba),
    pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    a.privilege_type,a.is_grantable)
 FROM pg_database d CROSS JOIN LATERAL aclexplode(coalesce(d.datacl,acldefault('d',d.datdba))) a
 WHERE d.datname=current_database()
 UNION ALL
 SELECT jsonb_build_array('schema',n.nspname,pg_get_userbyid(n.nspowner),
    pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    a.privilege_type,a.is_grantable)
 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
 WHERE n.nspname='public'
 UNION ALL
 SELECT jsonb_build_array('relation',c.relname,c.relkind,pg_get_userbyid(c.relowner),
    pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    a.privilege_type,a.is_grantable)
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner))) a
 WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
 UNION ALL
 SELECT jsonb_build_array('column',c.relname,t.attname,pg_get_userbyid(a.grantor),
    CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,a.privilege_type,a.is_grantable)
 FROM pg_attribute t JOIN pg_class c ON c.oid=t.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 CROSS JOIN LATERAL aclexplode(t.attacl) a WHERE n.nspname='public' AND t.attnum>0 AND NOT t.attisdropped
 UNION ALL
 SELECT jsonb_build_array('function',p.proname,pg_get_function_identity_arguments(p.oid),
    pg_get_userbyid(p.proowner),p.prosecdef,pg_get_userbyid(a.grantor),
    CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,a.privilege_type,a.is_grantable)
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
 WHERE n.nspname='public'
 UNION ALL
 SELECT jsonb_build_array('default-acl',pg_get_userbyid(d.defaclrole),coalesce(n.nspname,''),
    d.defaclobjtype,pg_get_userbyid(a.grantor),
    CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,a.privilege_type,a.is_grantable)
 FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
 CROSS JOIN LATERAL aclexplode(d.defaclacl) a
 WHERE d.defaclnamespace=0 OR n.nspname='public'
)
SELECT entry::text FROM entries ORDER BY entry::text COLLATE "C";
COMMIT;
