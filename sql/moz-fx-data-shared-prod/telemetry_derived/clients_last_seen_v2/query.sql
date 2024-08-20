-- Note that this query runs in the telemetry_derived dataset, so sees derived tables
-- rather than the user-facing views (so key_value structs haven't been eliminated, etc.)
WITH _current AS (
  SELECT
    -- In this raw table, we capture the history of activity over the past
    -- 28 days for each usage criterion as a single 64-bit integer. The
    -- rightmost bit represents whether the user was active in the current day.
    CAST(TRUE AS INT64) AS days_seen_bits,
    CAST(active_hours_sum > 0 AS INT64) & CAST(
      COALESCE(
        scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum,
        scalar_parent_browser_engagement_total_uri_count_sum
      ) > 0 AS INT64
    ) AS days_active_bits,
    -- For measuring Active MAU, where this is the days since this
    -- client_id was an Active User as defined by
    -- https://docs.telemetry.mozilla.org/cookbooks/active_dau.html
    CAST(
      COALESCE(
        scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum,
        scalar_parent_browser_engagement_total_uri_count_sum
      ) >= 1 AS INT64
    ) AS days_visited_1_uri_bits,
    CAST(
      COALESCE(
        scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum,
        scalar_parent_browser_engagement_total_uri_count_sum
      ) >= 5 AS INT64
    ) AS days_visited_5_uri_bits,
    CAST(
      COALESCE(
        scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum,
        scalar_parent_browser_engagement_total_uri_count_sum
      ) >= 10 AS INT64
    ) AS days_visited_10_uri_bits,
    CAST(active_hours_sum >= 0.011 AS INT64) AS days_had_8_active_ticks_bits,
    CAST(devtools_toolbox_opened_count_sum > 0 AS INT64) AS days_opened_dev_tools_bits,
    CAST(active_hours_sum > 0 AS INT64) AS days_interacted_bits,
    CAST(
      scalar_parent_browser_engagement_total_uri_count_sum >= 1 AS INT64
    ) AS days_visited_1_uri_normal_mode_bits,
    -- This field is only available after version 84, see the definition in clients_daily_v6 view
    CAST(
      IF(
        mozfun.norm.extract_version(app_display_version, 'major') < 84,
        NULL,
        scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum - COALESCE(
          scalar_parent_browser_engagement_total_uri_count_sum,
          0
        )
      ) >= 1 AS INT64
    ) AS days_visited_1_uri_private_mode_bits,
    -- We only trust profile_date if it is within one week of the ping submission,
    -- so we ignore any value more than seven days old.
    `moz-fx-data-shared-prod.udf.days_since_created_profile_as_28_bits`(
      DATE_DIFF(submission_date, SAFE.PARSE_DATE("%F", SUBSTR(profile_creation_date, 0, 10)), DAY)
    ) AS days_created_profile_bits,
    -- Experiments are an array, so we keep track of a usage bit pattern per experiment.
    ARRAY(
      SELECT AS STRUCT
        key AS experiment,
        value AS branch,
        1 AS bits
      FROM
        UNNEST(experiments)
    ) AS days_seen_in_experiment,
    * EXCEPT (submission_date)
  FROM
    `moz-fx-data-shared-prod.telemetry_derived.clients_daily_v6`
  WHERE
    submission_date = @submission_date
),
--
_previous AS (
  SELECT
    days_seen_bits,
    days_active_bits,
    days_visited_1_uri_bits,
    days_visited_5_uri_bits,
    days_visited_10_uri_bits,
    days_had_8_active_ticks_bits,
    days_opened_dev_tools_bits,
    days_interacted_bits,
    days_visited_1_uri_normal_mode_bits,
    days_visited_1_uri_private_mode_bits,
    days_created_profile_bits,
    days_seen_in_experiment,
    * EXCEPT (
      days_seen_bits,
      days_active_bits,
      days_visited_1_uri_bits,
      days_visited_5_uri_bits,
      days_visited_10_uri_bits,
      days_had_8_active_ticks_bits,
      days_opened_dev_tools_bits,
      days_interacted_bits,
      days_visited_1_uri_normal_mode_bits,
      days_visited_1_uri_private_mode_bits,
      days_created_profile_bits,
      days_seen_in_experiment,
      submission_date,
      first_seen_date,
      second_seen_date
    )
  FROM
    `moz-fx-data-shared-prod.telemetry_derived.clients_last_seen_v2`
  WHERE
    submission_date = DATE_SUB(@submission_date, INTERVAL 1 DAY)
    -- Filter out rows from yesterday that have now fallen outside the 28-day window.
    AND `moz-fx-data-shared-prod.udf.shift_28_bits_one_day`(days_seen_bits) > 0
),
staging AS (
  SELECT
    @submission_date AS submission_date,
    IF(cfs.first_seen_date > @submission_date, NULL, cfs.first_seen_date) AS first_seen_date,
    IF(cfs.second_seen_date > @submission_date, NULL, cfs.second_seen_date) AS second_seen_date,
    IF(_current.client_id IS NOT NULL, _current, _previous).* REPLACE (
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_seen_bits,
        _current.days_seen_bits
      ) AS days_seen_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_active_bits,
        _current.days_active_bits
      ) AS days_active_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_visited_1_uri_bits,
        _current.days_visited_1_uri_bits
      ) AS days_visited_1_uri_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_visited_5_uri_bits,
        _current.days_visited_5_uri_bits
      ) AS days_visited_5_uri_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_visited_10_uri_bits,
        _current.days_visited_10_uri_bits
      ) AS days_visited_10_uri_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_had_8_active_ticks_bits,
        _current.days_had_8_active_ticks_bits
      ) AS days_had_8_active_ticks_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_opened_dev_tools_bits,
        _current.days_opened_dev_tools_bits
      ) AS days_opened_dev_tools_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_interacted_bits,
        _current.days_interacted_bits
      ) AS days_interacted_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_visited_1_uri_normal_mode_bits,
        _current.days_visited_1_uri_normal_mode_bits
      ) AS days_visited_1_uri_normal_mode_bits,
      `moz-fx-data-shared-prod.udf.combine_adjacent_days_28_bits`(
        _previous.days_visited_1_uri_private_mode_bits,
        _current.days_visited_1_uri_private_mode_bits
      ) AS days_visited_1_uri_private_mode_bits,
      `moz-fx-data-shared-prod.udf.coalesce_adjacent_days_28_bits`(
        _previous.days_created_profile_bits,
        _current.days_created_profile_bits
      ) AS days_created_profile_bits,
      `moz-fx-data-shared-prod.udf.combine_experiment_days`(
        _previous.days_seen_in_experiment,
        _current.days_seen_in_experiment
      ) AS days_seen_in_experiment
    )
  FROM
    _current
  FULL JOIN
    _previous
    USING (client_id)
  LEFT JOIN
    `moz-fx-data-shared-prod.telemetry_derived.clients_first_seen_v2` AS cfs
    USING (client_id)
)
SELECT
  submission_date,
  first_seen_date,
  second_seen_date,
  days_seen_bits,
  days_visited_1_uri_bits,
  days_visited_5_uri_bits,
  days_visited_10_uri_bits,
  days_had_8_active_ticks_bits,
  days_opened_dev_tools_bits,
  days_interacted_bits,
  days_visited_1_uri_normal_mode_bits,
  days_visited_1_uri_private_mode_bits,
  days_created_profile_bits,
  days_seen_in_experiment,
  client_id,
  aborts_content_sum,
  aborts_gmplugin_sum,
  aborts_plugin_sum,
  active_addons_count_mean,
  active_addons,
  active_experiment_branch,
  active_experiment_id,
  active_hours_sum,
  addon_compatibility_check_enabled,
  app_build_id,
  app_display_version,
  app_name,
  app_version,
  attribution,
  blocklist_enabled,
  channel,
  client_clock_skew_mean,
  client_submission_latency_mean,
  cpu_cores,
  cpu_count,
  cpu_family,
  cpu_l2_cache_kb,
  cpu_l3_cache_kb,
  cpu_model,
  cpu_speed_mhz,
  cpu_stepping,
  cpu_vendor,
  crashes_detected_content_sum,
  crashes_detected_gmplugin_sum,
  crashes_detected_plugin_sum,
  crash_submit_attempt_content_sum,
  crash_submit_attempt_main_sum,
  crash_submit_attempt_plugin_sum,
  crash_submit_success_content_sum,
  crash_submit_success_main_sum,
  crash_submit_success_plugin_sum,
  default_search_engine,
  default_search_engine_data_load_path,
  default_search_engine_data_name,
  default_search_engine_data_origin,
  default_search_engine_data_submission_url,
  devtools_toolbox_opened_count_sum,
  distribution_id,
  e10s_enabled,
  env_build_arch,
  env_build_id,
  env_build_version,
  environment_settings_intl_accept_languages,
  environment_settings_intl_app_locales,
  environment_settings_intl_available_locales,
  environment_settings_intl_requested_locales,
  environment_settings_intl_system_locales,
  environment_settings_intl_regional_prefs_locales,
  experiments,
  first_paint_mean,
  flash_version,
  country,
  city,
  geo_subdivision1,
  geo_subdivision2,
  isp_name,
  isp_organization,
  gfx_features_advanced_layers_status,
  gfx_features_d2d_status,
  gfx_features_d3d11_status,
  gfx_features_gpu_process_status,
  histogram_parent_devtools_aboutdebugging_opened_count_sum,
  histogram_parent_devtools_animationinspector_opened_count_sum,
  histogram_parent_devtools_browserconsole_opened_count_sum,
  histogram_parent_devtools_canvasdebugger_opened_count_sum,
  histogram_parent_devtools_computedview_opened_count_sum,
  histogram_parent_devtools_custom_opened_count_sum,
  histogram_parent_devtools_developertoolbar_opened_count_sum,
  histogram_parent_devtools_dom_opened_count_sum,
  histogram_parent_devtools_eyedropper_opened_count_sum,
  histogram_parent_devtools_fontinspector_opened_count_sum,
  histogram_parent_devtools_inspector_opened_count_sum,
  histogram_parent_devtools_jsbrowserdebugger_opened_count_sum,
  histogram_parent_devtools_jsdebugger_opened_count_sum,
  histogram_parent_devtools_jsprofiler_opened_count_sum,
  histogram_parent_devtools_layoutview_opened_count_sum,
  histogram_parent_devtools_memory_opened_count_sum,
  histogram_parent_devtools_menu_eyedropper_opened_count_sum,
  histogram_parent_devtools_netmonitor_opened_count_sum,
  histogram_parent_devtools_options_opened_count_sum,
  histogram_parent_devtools_paintflashing_opened_count_sum,
  histogram_parent_devtools_picker_eyedropper_opened_count_sum,
  histogram_parent_devtools_responsive_opened_count_sum,
  histogram_parent_devtools_ruleview_opened_count_sum,
  histogram_parent_devtools_scratchpad_opened_count_sum,
  histogram_parent_devtools_scratchpad_window_opened_count_sum,
  histogram_parent_devtools_shadereditor_opened_count_sum,
  histogram_parent_devtools_storage_opened_count_sum,
  histogram_parent_devtools_styleeditor_opened_count_sum,
  histogram_parent_devtools_webaudioeditor_opened_count_sum,
  histogram_parent_devtools_webconsole_opened_count_sum,
  histogram_parent_devtools_webide_opened_count_sum,
  install_year,
  is_default_browser,
  is_wow64,
  locale,
  memory_mb,
  normalized_channel,
  normalized_os_version,
  os,
  os_service_pack_major,
  os_service_pack_minor,
  os_version,
  pings_aggregated_by_this_row,
  places_bookmarks_count_mean,
  places_pages_count_mean,
  plugin_hangs_sum,
  plugins_infobar_allow_sum,
  plugins_infobar_block_sum,
  plugins_infobar_shown_sum,
  plugins_notification_shown_sum,
  previous_build_id,
  profile_age_in_days,
  profile_creation_date,
  push_api_notify_sum,
  sample_id,
  sandbox_effective_content_process_level,
  scalar_combined_webrtc_nicer_stun_retransmits_sum,
  scalar_combined_webrtc_nicer_turn_401s_sum,
  scalar_combined_webrtc_nicer_turn_403s_sum,
  scalar_combined_webrtc_nicer_turn_438s_sum,
  scalar_content_navigator_storage_estimate_count_sum,
  scalar_content_navigator_storage_persist_count_sum,
  scalar_parent_aushelper_websense_reg_version,
  scalar_parent_browser_engagement_max_concurrent_tab_count_max,
  scalar_parent_browser_engagement_max_concurrent_window_count_max,
  scalar_parent_browser_engagement_tab_open_event_count_sum,
  scalar_parent_browser_engagement_total_uri_count_sum,
  scalar_parent_browser_engagement_unfiltered_uri_count_sum,
  scalar_parent_browser_engagement_unique_domains_count_max,
  scalar_parent_browser_engagement_unique_domains_count_mean,
  scalar_parent_browser_engagement_window_open_event_count_sum,
  scalar_parent_devtools_accessibility_node_inspected_count_sum,
  scalar_parent_devtools_accessibility_opened_count_sum,
  scalar_parent_devtools_accessibility_picker_used_count_sum,
  scalar_parent_devtools_accessibility_select_accessible_for_node_sum,
  scalar_parent_devtools_accessibility_service_enabled_count_sum,
  scalar_parent_devtools_copy_full_css_selector_opened_sum,
  scalar_parent_devtools_copy_unique_css_selector_opened_sum,
  scalar_parent_devtools_toolbar_eyedropper_opened_sum,
  scalar_parent_dom_contentprocess_troubled_due_to_memory_sum,
  scalar_parent_navigator_storage_estimate_count_sum,
  scalar_parent_navigator_storage_persist_count_sum,
  scalar_parent_storage_sync_api_usage_extensions_using_sum,
  search_cohort,
  search_count_abouthome,
  search_count_contextmenu,
  search_count_newtab,
  search_count_searchbar,
  search_count_system,
  search_count_urlbar,
  search_count_all,
  search_count_tagged_sap,
  search_count_tagged_follow_on,
  search_count_organic,
  search_count_urlbar_handoff,
  session_restored_mean,
  sessions_started_on_this_day,
  shutdown_kill_sum,
  subsession_hours_sum,
  ssl_handshake_result_failure_sum,
  ssl_handshake_result_success_sum,
  sync_configured,
  sync_count_desktop_mean,
  sync_count_mobile_mean,
  sync_count_desktop_sum,
  sync_count_mobile_sum,
  telemetry_enabled,
  timezone_offset,
  total_hours_sum,
  update_auto_download,
  update_channel,
  update_enabled,
  vendor,
  web_notification_shown_sum,
  windows_build_number,
  windows_ubr,
  fxa_configured,
  trackers_blocked_sum,
  submission_timestamp_min,
  ad_clicks_count_all,
  search_with_ads_count_all,
  scalar_parent_urlbar_impression_autofill_about_sum,
  scalar_parent_urlbar_impression_autofill_adaptive_sum,
  scalar_parent_urlbar_impression_autofill_origin_sum,
  scalar_parent_urlbar_impression_autofill_other_sum,
  scalar_parent_urlbar_impression_autofill_preloaded_sum,
  scalar_parent_urlbar_impression_autofill_url_sum,
  scalar_parent_telemetry_event_counts_sum,
  scalar_content_telemetry_event_counts_sum,
  scalar_parent_urlbar_searchmode_bookmarkmenu_sum,
  scalar_parent_urlbar_searchmode_handoff_sum,
  scalar_parent_urlbar_searchmode_keywordoffer_sum,
  scalar_parent_urlbar_searchmode_oneoff_sum,
  scalar_parent_urlbar_searchmode_other_sum,
  scalar_parent_urlbar_searchmode_shortcut_sum,
  scalar_parent_urlbar_searchmode_tabmenu_sum,
  scalar_parent_urlbar_searchmode_tabtosearch_sum,
  scalar_parent_urlbar_searchmode_tabtosearch_onboard_sum,
  scalar_parent_urlbar_searchmode_topsites_newtab_sum,
  scalar_parent_urlbar_searchmode_topsites_urlbar_sum,
  scalar_parent_urlbar_searchmode_touchbar_sum,
  scalar_parent_urlbar_searchmode_typed_sum,
  scalar_parent_os_environment_is_taskbar_pinned,
  scalar_parent_os_environment_launched_via_desktop,
  scalar_parent_os_environment_launched_via_start_menu,
  scalar_parent_os_environment_launched_via_taskbar,
  scalar_parent_os_environment_launched_via_other_shortcut,
  scalar_parent_os_environment_launched_via_other,
  search_count_webextension,
  search_count_alias,
  search_count_urlbar_searchmode,
  scalar_parent_browser_ui_interaction_preferences_pane_home_sum,
  scalar_parent_urlbar_picked_autofill_sum,
  scalar_parent_urlbar_picked_autofill_about_sum,
  scalar_parent_urlbar_picked_autofill_adaptive_sum,
  scalar_parent_urlbar_picked_autofill_origin_sum,
  scalar_parent_urlbar_picked_autofill_other_sum,
  scalar_parent_urlbar_picked_autofill_preloaded_sum,
  scalar_parent_urlbar_picked_autofill_url_sum,
  scalar_parent_urlbar_picked_bookmark_sum,
  scalar_parent_urlbar_picked_dynamic_sum,
  scalar_parent_urlbar_picked_extension_sum,
  scalar_parent_urlbar_picked_formhistory_sum,
  scalar_parent_urlbar_picked_history_sum,
  scalar_parent_urlbar_picked_keyword_sum,
  scalar_parent_urlbar_picked_remotetab_sum,
  scalar_parent_urlbar_picked_searchengine_sum,
  scalar_parent_urlbar_picked_searchsuggestion_sum,
  scalar_parent_urlbar_picked_switchtab_sum,
  scalar_parent_urlbar_picked_tabtosearch_sum,
  scalar_parent_urlbar_picked_tip_sum,
  scalar_parent_urlbar_picked_topsite_sum,
  scalar_parent_urlbar_picked_unknown_sum,
  scalar_parent_urlbar_picked_visiturl_sum,
  default_private_search_engine,
  default_private_search_engine_data_load_path,
  default_private_search_engine_data_name,
  default_private_search_engine_data_origin,
  default_private_search_engine_data_submission_url,
  search_counts,
  user_pref_browser_search_region,
  search_with_ads,
  ad_clicks,
  search_content_urlbar_sum,
  search_content_urlbar_handoff_sum,
  search_content_urlbar_searchmode_sum,
  search_content_contextmenu_sum,
  search_content_about_home_sum,
  search_content_about_newtab_sum,
  search_content_searchbar_sum,
  search_content_system_sum,
  search_content_webextension_sum,
  search_content_tabhistory_sum,
  search_content_reload_sum,
  search_content_unknown_sum,
  search_withads_urlbar_sum,
  search_withads_urlbar_handoff_sum,
  search_withads_urlbar_searchmode_sum,
  search_withads_contextmenu_sum,
  search_withads_about_home_sum,
  search_withads_about_newtab_sum,
  search_withads_searchbar_sum,
  search_withads_system_sum,
  search_withads_webextension_sum,
  search_withads_tabhistory_sum,
  search_withads_reload_sum,
  search_withads_unknown_sum,
  search_adclicks_urlbar_sum,
  search_adclicks_urlbar_handoff_sum,
  search_adclicks_urlbar_searchmode_sum,
  search_adclicks_contextmenu_sum,
  search_adclicks_about_home_sum,
  search_adclicks_about_newtab_sum,
  search_adclicks_searchbar_sum,
  search_adclicks_system_sum,
  search_adclicks_webextension_sum,
  search_adclicks_tabhistory_sum,
  search_adclicks_reload_sum,
  search_adclicks_unknown_sum,
  update_background,
  user_pref_browser_search_suggest_enabled,
  user_pref_browser_widget_in_navbar,
  user_pref_browser_urlbar_suggest_searches,
  user_pref_browser_urlbar_show_search_suggestions_first,
  user_pref_browser_urlbar_suggest_quicksuggest,
  user_pref_browser_urlbar_suggest_quicksuggest_sponsored,
  user_pref_browser_urlbar_quicksuggest_onboarding_dialog_choice,
  scalar_parent_browser_engagement_total_uri_count_normal_and_private_mode_sum,
  user_pref_browser_newtabpage_enabled,
  user_pref_app_shield_optoutstudies_enabled,
  contextual_services_quicksuggest_click_sum,
  contextual_services_quicksuggest_impression_sum,
  contextual_services_quicksuggest_help_sum,
  contextual_services_topsites_click_sum,
  contextual_services_topsites_impression_sum,
  user_pref_browser_urlbar_suggest_quicksuggest_nonsponsored,
  user_pref_browser_urlbar_quicksuggest_data_collection_enabled,
  scalar_a11y_hcm_foreground,
  scalar_a11y_hcm_background,
  a11y_theme,
  contextual_services_quicksuggest_help_nonsponsored_bestmatch_sum,
  contextual_services_quicksuggest_help_sponsored_bestmatch_sum,
  contextual_services_quicksuggest_block_nonsponsored_sum,
  contextual_services_quicksuggest_block_sponsored_sum,
  contextual_services_quicksuggest_block_sponsored_bestmatch_sum,
  contextual_services_quicksuggest_block_nonsponsored_bestmatch_sum,
  contextual_services_quicksuggest_click_sponsored_bestmatch_sum,
  contextual_services_quicksuggest_click_nonsponsored_bestmatch_sum,
  contextual_services_quicksuggest_impression_sponsored_bestmatch_sum,
  contextual_services_quicksuggest_impression_nonsponsored_bestmatch_sum,
  user_pref_browser_urlbar_suggest_bestmatch,
  scalar_parent_browser_ui_interaction_textrecognition_error_sum,
  text_recognition_interaction_timing_sum,
  text_recognition_interaction_timing_count_sum,
  scalar_parent_browser_ui_interaction_content_context_sum,
  text_recognition_api_performance_sum,
  text_recognition_api_performance_count_sum,
  text_recognition_text_length_sum,
  text_recognition_text_length_count_sum,
  scalar_parent_os_environment_launched_via_taskbar_private,
  dom_parentprocess_private_window_used,
  os_environment_is_taskbar_pinned_any,
  os_environment_is_taskbar_pinned_private_any,
  os_environment_is_taskbar_pinned_private,
  bookmark_migrations_quantity_chrome,
  bookmark_migrations_quantity_edge,
  bookmark_migrations_quantity_safari,
  bookmark_migrations_quantity_all,
  history_migrations_quantity_chrome,
  history_migrations_quantity_edge,
  history_migrations_quantity_safari,
  history_migrations_quantity_all,
  logins_migrations_quantity_chrome,
  logins_migrations_quantity_edge,
  logins_migrations_quantity_safari,
  logins_migrations_quantity_all,
  search_count_urlbar_persisted,
  search_content_urlbar_persisted_sum,
  search_withads_urlbar_persisted_sum,
  search_adclicks_urlbar_persisted_sum,
  media_play_time_ms_audio_sum,
  media_play_time_ms_video_sum,
  contextual_services_quicksuggest_block_dynamic_wikipedia_sum,
  contextual_services_quicksuggest_block_weather_sum,
  contextual_services_quicksuggest_click_dynamic_wikipedia_sum,
  contextual_services_quicksuggest_click_nonsponsored_sum,
  contextual_services_quicksuggest_click_sponsored_sum,
  contextual_services_quicksuggest_click_weather_sum,
  contextual_services_quicksuggest_help_dynamic_wikipedia_sum,
  contextual_services_quicksuggest_help_nonsponsored_sum,
  contextual_services_quicksuggest_help_sponsored_sum,
  contextual_services_quicksuggest_help_weather_sum,
  contextual_services_quicksuggest_impression_dynamic_wikipedia_sum,
  contextual_services_quicksuggest_impression_nonsponsored_sum,
  contextual_services_quicksuggest_impression_sponsored_sum,
  contextual_services_quicksuggest_impression_weather_sum,
  places_searchbar_cumulative_searches_sum,
  places_searchbar_cumulative_filter_count_sum,
  scalar_parent_sidebar_opened_sum,
  scalar_parent_sidebar_search_sum,
  scalar_parent_sidebar_link_sum,
  places_previousday_visits_mean,
  places_library_cumulative_bookmark_searches_sum,
  places_library_cumulative_history_searches_sum,
  places_bookmarks_searchbar_cumulative_searches_sum,
  scalar_parent_library_link_sum,
  scalar_parent_library_opened_sum,
  scalar_parent_library_search_sum,
  startup_profile_selection_reason_first,
  first_document_id,
  partner_id,
  distribution_version,
  distributor,
  distributor_channel,
  env_build_platform_version,
  env_build_xpcom_abi,
  geo_db_version,
  apple_model_id,
  max_subsession_counter,
  min_subsession_counter,
  startup_profile_selection_first_ping_only,
  days_active_bits,
  profile_group_id
FROM
  staging a
