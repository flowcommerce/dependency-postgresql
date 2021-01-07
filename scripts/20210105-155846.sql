alter table projects add column branch text check(util.null_or_non_empty_trimmed_string(branch));
