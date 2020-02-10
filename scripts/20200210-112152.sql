update resolvers
set uri = replace(uri, 'http://', 'https://')
where visibility = 'public';
