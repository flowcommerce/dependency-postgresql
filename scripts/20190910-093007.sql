alter table items alter column hash_code drop default;
alter table items drop constraint items_organization_id_object_id_key;
