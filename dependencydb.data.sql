--
-- PostgreSQL database dump
--

-- Dumped from database version 15.5
-- Dumped by pg_dump version 15.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: part_config; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.part_config (parent_table, control, partition_interval, partition_type, premake, automatic_maintenance, template_table, retention, retention_schema, retention_keep_index, retention_keep_table, epoch, constraint_cols, optimize_constraint, infinite_time_partitions, datetime_string, jobmon, sub_partition_set_full, undo_in_progress, inherit_privileges, constraint_valid, ignore_default_data, default_table, date_trunc_interval, maintenance_order, retention_keep_publication, maintenance_last_run) FROM stdin;
journal.github_users	journal_timestamp	1 mon	range	4	on	partman5.template_journal_github_users	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.334247+00
journal.last_emails	journal_timestamp	1 mon	range	4	on	partman5.template_journal_last_emails	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.353331+00
journal.user_identifiers	journal_timestamp	1 mon	range	4	on	partman5.template_journal_user_identifiers	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.375335+00
journal.libraries	journal_timestamp	1 mon	range	4	on	partman5.template_journal_libraries	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.388278+00
journal.user_organizations	journal_timestamp	1 mon	range	4	on	partman5.template_journal_user_organizations	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.409367+00
journal.library_versions	journal_timestamp	1 mon	range	4	on	partman5.template_journal_library_versions	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.42933+00
journal.users	journal_timestamp	1 mon	range	4	on	partman5.template_journal_users	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.446209+00
journal.memberships	journal_timestamp	1 mon	range	4	on	partman5.template_journal_memberships	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.459593+00
journal.organizations	journal_timestamp	1 mon	range	4	on	partman5.template_journal_organizations	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.473643+00
journal.binary_versions	journal_timestamp	1 mon	range	4	on	partman5.template_journal_binary_versions	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.490158+00
journal.project_binaries	journal_timestamp	1 mon	range	4	on	partman5.template_journal_project_binaries	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.503496+00
journal.project_libraries	journal_timestamp	1 mon	range	4	on	partman5.template_journal_project_libraries	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.524328+00
journal.projects	journal_timestamp	1 mon	range	4	on	partman5.template_journal_projects	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.540437+00
journal.recommendations	journal_timestamp	1 mon	range	4	on	partman5.template_journal_recommendations	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.555872+00
journal.resolvers	journal_timestamp	1 mon	range	4	on	partman5.template_journal_resolvers	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.570351+00
journal.subscriptions	journal_timestamp	1 mon	range	4	on	partman5.template_journal_subscriptions	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.239795+00
journal.binaries	journal_timestamp	1 mon	range	4	on	partman5.template_journal_binaries	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.289122+00
journal.tokens	journal_timestamp	1 mon	range	4	on	partman5.template_journal_tokens	3 months	\N	f	f	none	\N	30	t	YYYYMMDD	t	f	f	f	t	t	f	\N	\N	f	2024-04-24 11:52:36.31116+00
\.


--
-- Data for Name: part_config_sub; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.part_config_sub (sub_parent, sub_control, sub_partition_interval, sub_partition_type, sub_premake, sub_automatic_maintenance, sub_template_table, sub_retention, sub_retention_schema, sub_retention_keep_index, sub_retention_keep_table, sub_epoch, sub_constraint_cols, sub_optimize_constraint, sub_infinite_time_partitions, sub_jobmon, sub_inherit_privileges, sub_constraint_valid, sub_ignore_default_data, sub_default_table, sub_date_trunc_interval, sub_maintenance_order, sub_retention_keep_publication) FROM stdin;
\.


--
-- Data for Name: template_journal_binaries; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_binaries (id, organization_id, name, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_binary_versions; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_binary_versions (id, binary_id, version, sort_key, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_github_users; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_github_users (id, user_id, github_user_id, login, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_last_emails; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_last_emails (id, user_id, publication, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_libraries; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_libraries (id, organization_id, group_id, artifact_id, resolver_id, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_library_versions; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_library_versions (id, library_id, version, cross_build_version, sort_key, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_memberships; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_memberships (id, user_id, organization_id, role, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_organizations; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_organizations (id, user_id, key, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_project_binaries; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_project_binaries (id, project_id, name, version, path, binary_id, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_project_libraries; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_project_libraries (id, project_id, group_id, artifact_id, version, cross_build_version, path, library_id, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_projects; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_projects (id, organization_id, user_id, visibility, scms, name, uri, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_recommendations; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_recommendations (id, project_id, type, object_id, name, from_version, to_version, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_resolvers; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_resolvers (id, visibility, organization_id, uri, "position", credentials, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_subscriptions; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_subscriptions (id, user_id, publication, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_tokens; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_tokens (id, user_id, tag, token, number_views, description, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_user_identifiers; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_user_identifiers (id, user_id, value, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_user_organizations; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_user_organizations (id, user_id, organization_id, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: template_journal_users; Type: TABLE DATA; Schema: partman5; Owner: api
--

COPY partman5.template_journal_users (id, email, first_name, last_name, avatar_url, created_at, updated_by_user_id, journal_timestamp, journal_operation, journal_id) FROM stdin;
\.


--
-- Data for Name: bootstrap_scripts; Type: TABLE DATA; Schema: schema_evolution_manager; Owner: api
--

COPY schema_evolution_manager.bootstrap_scripts (id, filename, created_at) FROM stdin;
1	20130318-105434.sql	2016-02-27 03:53:37.222788+00
2	20130318-105456.sql	2016-02-27 03:53:37.313285+00
\.


--
-- Data for Name: scripts; Type: TABLE DATA; Schema: schema_evolution_manager; Owner: api
--

COPY schema_evolution_manager.scripts (id, filename, created_at) FROM stdin;
1	20151107-131159.sql	2016-02-27 03:53:37.602741+00
2	20151108-004020.sql	2016-02-27 03:53:42.604042+00
3	20151110-113226.sql	2016-02-27 03:53:42.686844+00
4	20151128-124823.sql	2016-02-27 03:53:43.436432+00
5	20151128-155025.sql	2016-02-27 03:53:44.189921+00
6	20151202-153045.sql	2016-02-27 03:53:44.907925+00
7	20151203-121952.sql	2016-02-27 03:53:45.735497+00
8	20151204-221914.sql	2016-02-27 03:53:45.859024+00
9	20151206-214157.sql	2016-02-27 03:53:45.947094+00
10	20151211-011326.sql	2016-02-27 03:53:46.7055+00
11	20151211-173049.sql	2016-02-27 03:53:47.461707+00
12	20151213-111905.sql	2016-02-27 03:53:48.243678+00
13	20151214-064219.sql	2016-02-27 03:53:49.044946+00
14	20151217-142514.sql	2016-02-27 03:53:50.617945+00
15	20151221-163929.sql	2016-02-27 03:53:51.432294+00
16	20160107-220237.sql	2016-02-27 03:53:51.540827+00
17	20160107-230605.sql	2016-02-27 03:53:51.646727+00
18	20160823-144517.sql	2017-11-19 16:40:08.340704+00
19	20160909-093108.sql	2017-11-19 16:40:08.454832+00
20	20180206-151612.sql	2018-02-07 18:21:59.299916+00
21	20181029-115650.sql	2018-10-29 15:59:33.971741+00
22	20190906-193722.sql	2019-09-10 13:28:54.886171+00
23	20190906-225730.sql	2019-09-10 13:28:54.968212+00
24	20190909-173126.sql	2019-09-10 13:28:55.297451+00
25	20190909-175225.sql	2019-09-10 13:28:55.391229+00
26	20190910-093007.sql	2019-09-10 14:08:52.252202+00
27	20190926-142610.sql	2019-09-27 00:19:57.319821+00
28	20200210-112152.sql	2020-02-10 16:46:24.572738+00
29	20200418-181050.sql	2020-04-18 22:11:42.633106+00
30	20200422-145650.sql	2020-04-22 19:32:53.802214+00
31	20200422-150038.sql	2020-04-22 19:32:53.910201+00
32	20210105-155846.sql	2021-01-07 22:27:34.260962+00
33	20210107-155820.sql	2021-01-07 22:27:34.432462+00
34	20210107-175803.sql	2021-01-08 16:26:05.539984+00
35	20231129-221230.sql	2023-12-01 18:58:03.615638+00
36	20240201-173934.sql	2024-02-02 17:23:45.368129+00
37	20240201-173935.sql	2024-02-02 17:23:45.488063+00
38	20240201-173936.sql	2024-02-02 17:23:45.610198+00
39	20240313-113852.sql	2024-03-13 14:41:33.433877+00
40	20240424-104449.sql	2024-04-24 10:56:35.495762+00
41	20240424-104450.sql	2024-04-24 10:56:35.728407+00
\.


--
-- Name: bootstrap_scripts_id_seq; Type: SEQUENCE SET; Schema: schema_evolution_manager; Owner: api
--

SELECT pg_catalog.setval('schema_evolution_manager.bootstrap_scripts_id_seq', 2, true);


--
-- Name: scripts_id_seq; Type: SEQUENCE SET; Schema: schema_evolution_manager; Owner: api
--

SELECT pg_catalog.setval('schema_evolution_manager.scripts_id_seq', 41, true);


--
-- PostgreSQL database dump complete
--

