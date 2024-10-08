CREATE OR REPLACE VIEW
  `moz-fx-data-shared-prod.mozilla_vpn.funnel_ga_to_subscriptions`
AS
SELECT
  *
FROM
  `moz-fx-data-shared-prod`.mozilla_vpn_derived.funnel_ga_to_subscriptions_v1
WHERE
  `date` <= '2024-06-28'
UNION ALL
SELECT
  *
FROM
  `moz-fx-data-shared-prod`.mozilla_vpn_derived.funnel_ga_to_subscriptions_v2
WHERE
  `date` > '2024-06-28'
