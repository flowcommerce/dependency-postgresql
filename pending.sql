alter table items alter column hash_code drop default;
drop index items_organization_id_object_id_key;
