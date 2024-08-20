SELECT
  TO_HEX(uid) AS uid,
  group_id,
  role,
  managed_by,
  SAFE.TIMESTAMP_MILLIS(SAFE_CAST(expires AS INT)) AS expires,
  notes,
FROM
  EXTERNAL_QUERY(
    "moz-fx-fxa-nonprod.us.fxa-rds-nonprod-stage-fxa",
    """SELECT
         uid,
         group_id,
         role,
         managed_by,
         expires,
         notes
       FROM
         fxa.accountGroups
    """
  )
