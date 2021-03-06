# Generated via https://github.com/mozilla/bigquery-etl/blob/master/bigquery_etl/query_scheduling/generate_airflow_dags.py

from airflow import DAG
from airflow.operators.sensors import ExternalTaskSensor
import datetime
from utils.gcp import bigquery_etl_query

default_args = {
    "owner": "frank@mozilla.com",
    "start_date": datetime.datetime(2020, 9, 9, 0, 0),
    "email": ["frank@mozilla.com"],
    "depends_on_past": False,
    "retry_delay": datetime.timedelta(seconds=1800),
    "email_on_failure": True,
    "email_on_retry": True,
    "retries": 2,
}

with DAG(
    "bqetl_fenix_event_rollup", default_args=default_args, schedule_interval="0 2 * * *"
) as dag:

    org_mozilla_firefox__event_types__v1 = bigquery_etl_query(
        task_id="org_mozilla_firefox__event_types__v1",
        destination_table=None,
        dataset_id="org_mozilla_firefox",
        project_id="moz-fx-data-shared-prod",
        owner="frank@mozilla.com",
        email=["frank@mozilla.com"],
        date_partition_parameter="submission_date",
        depends_on_past=False,
        parameters=["submission_date:DATE:{{ds}}"],
        sql_file_path="sql/org_mozilla_firefox/event_types_v1/query.sql",
        dag=dag,
    )

    org_mozilla_firefox_derived__event_types__v1 = bigquery_etl_query(
        task_id="org_mozilla_firefox_derived__event_types__v1",
        destination_table="event_types_v1",
        dataset_id="org_mozilla_firefox_derived",
        project_id="moz-fx-data-shared-prod",
        owner="frank@mozilla.com",
        email=["frank@mozilla.com"],
        date_partition_parameter="submission_date",
        depends_on_past=True,
        dag=dag,
    )

    org_mozilla_firefox_derived__events_daily__v1 = bigquery_etl_query(
        task_id="org_mozilla_firefox_derived__events_daily__v1",
        destination_table="events_daily_v1",
        dataset_id="org_mozilla_firefox_derived",
        project_id="moz-fx-data-shared-prod",
        owner="frank@mozilla.com",
        email=["frank@mozilla.com"],
        date_partition_parameter="submission_date",
        depends_on_past=False,
        dag=dag,
    )

    org_mozilla_firefox__event_types__v1.set_upstream(
        org_mozilla_firefox_derived__event_types__v1
    )

    wait_for_copy_deduplicate_all = ExternalTaskSensor(
        task_id="wait_for_copy_deduplicate_all",
        external_dag_id="copy_deduplicate",
        external_task_id="copy_deduplicate_all",
        execution_delta=datetime.timedelta(seconds=3600),
        check_existence=True,
        mode="reschedule",
        pool="DATA_ENG_EXTERNALTASKSENSOR",
    )

    org_mozilla_firefox_derived__event_types__v1.set_upstream(
        wait_for_copy_deduplicate_all
    )

    org_mozilla_firefox_derived__events_daily__v1.set_upstream(
        wait_for_copy_deduplicate_all
    )

    org_mozilla_firefox_derived__events_daily__v1.set_upstream(
        org_mozilla_firefox__event_types__v1
    )
