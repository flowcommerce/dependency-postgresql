alter table projects alter column branch set not null;
alter table projects drop constraint projects_branch_check;
alter table projects add constraint projects_branch_check check(util.non_empty_trimmed_string(branch));
