CREATE SCHEMA pg_jobmon;

SET search_path TO  pg_jobmon;

CREATE TABLE job_log (
    job_id bigint NOT NULL,
    owner text NOT NULL,
    job_name text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone,
    status text,
    pid integer NOT NULL,
    CONSTRAINT job_log_job_id_pkey PRIMARY KEY (job_id)
);
CREATE INDEX job_log_job_name_idx ON job_log (job_name);
CREATE INDEX job_log_start_time_idx ON job_log (start_time);
CREATE INDEX job_log_status_idx ON job_log (status);
CREATE INDEX job_log_pid_idx ON job_log (pid);
CREATE SEQUENCE job_log_job_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE job_log_job_id_seq OWNED BY job_log.job_id;
ALTER TABLE job_log ALTER COLUMN job_id SET DEFAULT nextval('job_log_job_id_seq'::regclass);


CREATE TABLE job_detail (
    job_id bigint NOT NULL,
    step_id bigint NOT NULL,
    action text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone,
    elapsed_time real,
    status text,
    message text,
    CONSTRAINT job_detail_step_id_pkey PRIMARY KEY (step_id),
    CONSTRAINT job_detail_job_id_fkey FOREIGN KEY (job_id) REFERENCES job_log(job_id)
);
CREATE INDEX job_detail_job_id_idx ON job_detail (job_id);
CREATE SEQUENCE job_detail_step_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE job_detail_step_id_seq OWNED BY job_detail.step_id;
ALTER TABLE job_detail ALTER COLUMN step_id SET DEFAULT nextval('job_detail_step_id_seq'::regclass);


CREATE TABLE job_check_log (
    job_id bigint NOT NULL,
    job_name text NOT NULL
);
SELECT pg_catalog.pg_extension_config_dump('job_check_log', '');


CREATE TABLE dblink_mapping (
    username text NOT NULL,
    pwd text
);
SELECT pg_catalog.pg_extension_config_dump('dblink_mapping', '');


CREATE TABLE job_check_config (
    job_name text NOT NULL,
    warn_threshold interval NOT NULL,
    error_threshold interval NOT NULL,
    active boolean DEFAULT false NOT NULL,
--    escalate text DEFAULT 'email'::text NOT NULL,
    sensitivity smallint DEFAULT 0 NOT NULL,
    CONSTRAINT job_check_config_job_name_pkey PRIMARY KEY (job_name)
);
SELECT pg_catalog.pg_extension_config_dump('job_check_config', '');


CREATE TABLE job_status_text (
    alert_code  integer NOT NULL,
    alert_text  text NOT NULL,
    CONSTRAINT job_status_text_alert_code_pkey PRIMARY KEY (alert_code)
);
SELECT pg_catalog.pg_extension_config_dump('job_status_text', '');
INSERT INTO job_status_text (alert_code, alert_text) VALUES (1, 'OK');
INSERT INTO job_status_text (alert_code, alert_text) VALUES (2, 'WARNING');
INSERT INTO job_status_text (alert_code, alert_text) VALUES (3, 'CRITICAL');


-- ########## pg_jobmon extension function definitions ##########
/*
 *  dblink Authentication mapping
 */
CREATE FUNCTION auth() RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_username  text;
    v_password  text;
    v_auth      text;
BEGIN
    SELECT username, pwd INTO v_username, v_password FROM dblink_mapping;
    IF v_username IS NULL THEN
        RETURN '';
    END IF;

    v_auth := 'user='||v_username;
    IF v_password IS NOT NULL THEN
        v_auth := v_auth || ' password='||v_password;
    END IF;
    v_auth := v_auth || ' ';
    RETURN v_auth;    
END
$$;

/*
 *  Add Job Autonmous
 */
CREATE FUNCTION _autonomous_add_job(p_owner text, p_job_name text, p_pid integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_id bigint;
BEGIN
    SELECT nextval('job_log_job_id_seq') INTO v_job_id;

    INSERT INTO job_log (job_id, owner, job_name, start_time, pid)
    VALUES (v_job_id, p_owner, upper(p_job_name), current_timestamp, p_pid); 

    RETURN v_job_id; 
END
$$;

/*
 *  Add Job
 */
CREATE FUNCTION add_job(p_job_name text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE 
    v_job_id bigint;
    v_remote_query text;
    v_dblink_schema text;
BEGIN
    SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
    
    v_remote_query := 'SELECT _autonomous_add_job (' ||
        quote_literal(current_user) || ',' ||
        quote_literal(p_job_name) || ',' ||
        pg_backend_pid() || ')';

    EXECUTE 'SELECT job_id FROM ' || v_dblink_schema || '.dblink('''||auth()||'dbname='|| current_database() ||
        ''','|| quote_literal(v_remote_query) || ',TRUE) t (job_id int)' INTO v_job_id;      

    IF v_job_id IS NULL THEN
        RAISE EXCEPTION 'Job creation failed';
    END IF;

    RETURN v_job_id;
END
$$;

/*
 *  Add Step Autonomous
 */
CREATE FUNCTION _autonomous_add_step(p_job_id bigint, p_action text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_step_id bigint;
BEGIN
    SELECT nextval('job_detail_step_id_seq') INTO v_step_id;

    INSERT INTO job_detail (job_id, step_id, action, start_time)
    VALUES (p_job_id, v_step_id, p_action, current_timestamp);

    RETURN v_step_id;
END
$$;

/*
 *  Add Step
 */
CREATE FUNCTION add_step(p_job_id bigint, p_action text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE 
    v_step_id bigint;
    v_remote_query text;
    v_dblink_schema text;
    
BEGIN

    SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
    
    v_remote_query := 'SELECT _autonomous_add_step (' ||
        p_job_id || ',' ||
        quote_literal(p_action) || ')';

    EXECUTE 'SELECT step_id FROM ' || v_dblink_schema || '.dblink('''||auth()||'dbname='|| current_database() ||
        ''','|| quote_literal(v_remote_query) || ',TRUE) t (step_id int)' INTO v_step_id;      

    IF v_step_id IS NULL THEN
        RAISE EXCEPTION 'Job creation failed';
    END IF;

    RETURN v_step_id;
END
$$;

/*
 *  Update Step Autonomous
 */
CREATE FUNCTION _autonomous_update_step(p_step_id bigint, p_status text, p_message text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_numrows integer;
BEGIN
    UPDATE job_detail SET 
        end_time = current_timestamp,
        elapsed_time = date_part('epoch',now() - start_time)::real,
        status = p_status,
        message = p_message
    WHERE step_id = p_step_id; 
    GET DIAGNOSTICS v_numrows = ROW_COUNT;
    RETURN v_numrows;
END
$$;

/*
 *  Update Step
 */
CREATE FUNCTION update_step(p_step_id bigint, p_status text, p_message text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_remote_query text;
    v_dblink_schema text;
BEGIN
    SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
    
    v_remote_query := 'SELECT _autonomous_update_step ('||
    p_step_id || ',' ||
    quote_literal(p_status) || ',' ||
    quote_literal(p_message) || ')';

    EXECUTE 'SELECT devnull FROM ' || v_dblink_schema || '.dblink('''||auth()||'dbname='|| current_database() ||
        ''','|| quote_literal(v_remote_query) || ',TRUE) t (devnull int)';  
END
$$;

/*
 *  Close Job Autonomous
 */
CREATE FUNCTION _autonomous_close_job(p_job_id bigint) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_numrows integer;
    v_status text;
BEGIN    
    EXECUTE 'SELECT alert_text FROM job_status_text WHERE alert_code = 1'
        INTO v_status;
    UPDATE job_log SET
        end_time = current_timestamp,
        status = v_status
    WHERE job_id = p_job_id;
    GET DIAGNOSTICS v_numrows = ROW_COUNT;
    RETURN v_numrows;
END
$$;

/*
 *  Close Job
 */
CREATE FUNCTION close_job(p_job_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_remote_query text;
    v_dblink_schema text;
BEGIN

    SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
    
    v_remote_query := 'SELECT _autonomous_close_job('||p_job_id||')'; 

    EXECUTE 'SELECT devnull FROM ' || v_dblink_schema || '.dblink('''||auth()||'dbname='|| current_database() ||
        ''',' || quote_literal(v_remote_query) || ',TRUE) t (devnull int)';  
END
$$;

/*
 *  Fail Job Autonomous
 */
CREATE FUNCTION _autonomous_fail_job(p_job_id bigint) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_numrows integer;
    v_status text;
BEGIN
    EXECUTE 'SELECT alert_text FROM job_status_text WHERE alert_code = 3'
        INTO v_status;
    UPDATE job_log SET
        end_time = current_timestamp,
        status = v_status
    WHERE job_id = p_job_id;
    GET DIAGNOSTICS v_numrows = ROW_COUNT;
    RETURN v_numrows;
END
$$;

/*
 *  Fail Job
 */
CREATE FUNCTION fail_job(p_job_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_remote_query text;
    v_dblink_schema text;
BEGIN
    
    SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
    
    v_remote_query := 'SELECT _autonomous_fail_job('||p_job_id||')'; 

    EXECUTE 'SELECT devnull FROM ' || v_dblink_schema || '.dblink('''||auth()||'dbname='|| current_database() ||
        ''',' || quote_literal(v_remote_query) || ',TRUE) t (devnull int)';  

END
$$;

/*
 *  Cancel Job
 */
CREATE FUNCTION cancel_job(p_job_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_pid       integer;
    v_step_id   bigint;
    v_status    text;
BEGIN
    EXECUTE 'SELECT alert_text FROM job_status_text WHERE alert_code = 3'
        INTO v_status;
    SELECT pid INTO v_pid FROM job_log WHERE job_id = p_job_id;
    PERFORM pg_cancel_backend(v_pid);
    SELECT max(step_id) INTO v_step_id FROM job_detail WHERE job_id = p_job_id;
    PERFORM _autonomous_update_step(v_step_id, v_status, 'Manually cancelled via call to cancel_job()');
    PERFORM _autonomous_fail_job(p_job_id);
    RETURN true;
END
$$;


/*
 *  Log a complete, single query job
 */
CREATE FUNCTION sql_job(p_job_name text, p_sql text) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_id    bigint;
    v_step_id   bigint;
    v_numrows   bigint;
    v_adv_lock  boolean;
    v_return    text;
BEGIN
    v_job_id := add_job(p_job_name);
    
    -- Take advisory lock to prevent multiple calls to function overlapping
    v_adv_lock := pg_try_advisory_lock(hashtext('sql_log'), hashtext(p_job_name));
    IF v_adv_lock = 'false' THEN
        v_step_id := add_step(v_job_id,'Obtaining advisory lock for job: '||v_job_name);
        PERFORM update_step(v_step_id, 'OK','Found concurrent job. Exiting gracefully');
        PERFORM close_job(v_job_id);
        RETURN 'Concurrent job found. Obtaining advisory lock FAILED for job: %', v_job_name;
    END IF;

    v_step_id := add_step(v_job_id, 'Running sql: ' || quote_literal(p_sql));
    EXECUTE p_sql;
    GET DIAGNOSTICS v_numrows = ROW_COUNT;
    PERFORM update_step(v_step_id, 'OK', 'Rows affected: ' || v_numrows);
    PERFORM close_job(v_job_id);
    
    PERFORM pg_advisory_unlock(hashtext('sql_log'), hashtext(p_job_name));

    RETURN 'Job logged with job id: ' || v_job_id;

EXCEPTION
    WHEN OTHERS THEN 
        PERFORM update_step(v_step_id, 'CRITICAL', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        PERFORM fail_job(v_job_id);
        PERFORM pg_advisory_unlock(hashtext('sql_log'), hashtext(p_job_name));
        RETURN 'Job ID ' || v_job_id || ' failed. See job_detail table for more details';
END
$$;


/*
 *  Log a single query step
 */
CREATE FUNCTION sql_step(p_job_id bigint, p_action text, p_sql text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_step_id   bigint;
    v_numrows   bigint;
BEGIN
    v_step_id := add_step(p_job_id, p_action);
    EXECUTE p_sql;
    GET DIAGNOSTICS v_numrows = ROW_COUNT;
    PERFORM update_step(v_step_id, 'OK', 'Rows affected: ' || v_numrows);
    PERFORM close_job(p_job_id);

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM update_step(v_step_id, 'CRITICAL', 'ERROR: '||coalesce(SQLERRM,'unknown'));
        RETURN false;
END
$$;


/*
 *  Job Monitor Trigger
 */
CREATE FUNCTION job_monitor() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_ok    text;
    v_bad   text;
BEGIN
    SELECT alert_text INTO v_ok FROM job_status_text WHERE alert_code = 1;
    SELECT alert_text INTO v_bad FROM job_status_text WHERE alert_code = 3;
    IF NEW.status = v_ok THEN
        DELETE FROM job_check_log WHERE job_name = NEW.job_name;
    ELSIF NEW.status = v_bad THEN
        INSERT INTO job_check_log (job_id, job_name) VALUES (NEW.job_id, NEW.job_name);
    ELSE
        -- Do nothing
    END IF;

    return null;
END
$$;
-- Create trigger on table
CREATE TRIGGER trg_job_monitor AFTER UPDATE ON job_log FOR EACH ROW EXECUTE PROCEDURE job_monitor();

/*
 *  Check Job status
 *
 * p_history is how far into job_log's past the check will go. Don't go further back than the longest job's interval that is contained
 *      in job_check_config to keep check efficient
 * Return code 1 means a successful job run
 * Return code 2 is for use with jobs that support a warning indicator. Not critical, but someone should look into it
 * Return code 3 is for use with a critical job failure 
 */
CREATE FUNCTION check_job_status(p_history interval, OUT alert_code integer, OUT alert_text text) 
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_jobs                  RECORD;
    v_job_errors            RECORD;
    v_count                 int = 1;
    v_trouble               text[];
    v_alert_code_3          text;
BEGIN
    
    alert_text := '(';
    alert_code := 1;
    -- Generic check for jobs without special monitoring. Should error on 3 failures
    FOR v_job_errors IN SELECT l.job_name FROM job_check_log l 
        WHERE l.job_name NOT IN (SELECT c.job_name FROM job_check_config c WHERE l.job_name <> c.job_name) GROUP BY l.job_name HAVING count(*) > 2
    LOOP
        v_trouble[v_count] := v_job_errors.job_name;
        v_count := v_count+1;
    END LOOP;
    
    IF array_upper(v_trouble,1) > 0 THEN
        alert_code = 3;
        alert_text := alert_text || 'Jobs w/ 3 consecutive errors: '||array_to_string(v_trouble,', ')||'; ';
    END IF;

    SELECT jt.alert_text INTO v_alert_code_3 FROM job_status_text jt WHERE jt.alert_code = 3;
    
    -- Jobs with special monitoring (threshold different than 3 errors; must run within a timeframe; etc)
    FOR v_jobs IN 
                SELECT
                    job_name,
                    current_timestamp,
                    current_timestamp - end_time AS last_run_time,  
                    CASE
                        WHEN (SELECT count(*) FROM job_check_log WHERE job_name = job_check_config.job_name) > sensitivity THEN 'ERROR'  
                        WHEN end_time < (current_timestamp - error_threshold) THEN 'ERROR' 
                        WHEN end_time < (current_timestamp - warn_threshold) THEN 'WARNING'
                        ELSE 'OK'
                    END AS error_code,
                    CASE
                        WHEN status = v_alert_code_3 THEN 'CRITICAL'
                        WHEN status is null THEN 'MISSING' 
                        WHEN (end_time < current_timestamp - error_threshold) OR (end_time < current_timestamp - warn_threshold) THEN 
                            CASE 
                                WHEN status = 'OK' THEN 'MISSING'
                                ELSE status
                            END
                        ELSE status
                    END AS job_status
                FROM
                    job_check_config 
                    LEFT JOIN (SELECT
                                    job_name,
                                    max(start_time) AS start_time,
                                    max(end_time) AS end_time 
                                FROM
                                    job_log
                                WHERE
                                    (end_time > now() - p_history OR end_time IS NULL)
                                GROUP BY 
                                    job_name 
                                ) last_job using (job_name)
                    LEFT JOIN (SELECT 
                                    job_name,    
                                    start_time, 
                                    coalesce(status,
                                    (SELECT CASE WHEN (SELECT count(*) FROM pg_locks WHERE not granted and pid = m.pid) > 0 THEN 'BLOCKED' ELSE NULL END),
                                    (SELECT CASE WHEN (SELECT count(*) FROM pg_stat_activity WHERE procpid = m.pid) > 0 THEN 'RUNNING' ELSE NULL END),
                                    'FOOBAR') AS status
                                FROM
                                    job_log m 
                                WHERE 
                                    start_time > now() - p_history
                                ) lj_status using (job_name,start_time)   
                 WHERE active      
LOOP

    IF v_jobs.error_code = 'ERROR' THEN
        alert_code := 3;
        alert_text := alert_text || v_jobs.job_name || ': ' || coalesce(v_jobs.job_status,'null??');
    END IF;

    IF v_jobs.error_code = 'WARNING' THEN
        IF alert_code <> 3 THEN
            alert_code := 2;
        END IF;
        alert_text := alert_text || v_jobs.job_name || ': ' || coalesce(v_jobs.job_status,'null??');
    END IF;
    
    IF v_jobs.job_status = 'BLOCKED' THEN
         alert_text := alert_text || ' - Object lock is blocking job completion';
    ELSIF v_jobs.job_status = 'MISSING' THEN
        IF v_jobs.last_run_time IS NULL THEN  
            alert_text := alert_text || ' - Last run over ' || p_history || ' ago. Check job_log for more details';
        ELSE
            alert_text := alert_text || ' - Last run at ' || current_timestamp - v_jobs.last_run_time;
        END IF;
    END IF;

    IF alert_code <> 1 AND v_jobs.job_status <> 'OK' THEN
        alert_text := alert_text || '; ';
    END IF;

END LOOP;

IF alert_text = '(' THEN
    alert_text := alert_text || 'All jobs run successfully';
END IF;

alert_text := alert_text || ')';

END
$$;

/*
 *  Show Jobs By Exact Name
 */
CREATE FUNCTION show_job(p_name text, int default 10) RETURNS SETOF job_log
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_list      job_log%ROWTYPE;
BEGIN
    FOR v_job_list IN SELECT job_id, owner, job_name, start_time, end_time, status, pid  
        FROM job_log
        WHERE job_name = upper(p_name)
        ORDER BY job_id DESC
        LIMIT $2
    LOOP
        RETURN NEXT v_job_list; 
    END LOOP;

    RETURN;
END
$$;

/*
 *  Show Jobs Like Name
 */
CREATE FUNCTION show_job_like(p_name text, int default 10) RETURNS SETOF job_log
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_list      job_log%ROWTYPE;
BEGIN
    FOR v_job_list IN SELECT job_id, owner, job_name, start_time, end_time, status, pid  
        FROM job_log
        WHERE job_name ~ upper(p_name)
        ORDER BY job_id DESC
        LIMIT $2
    LOOP
        RETURN NEXT v_job_list; 
    END LOOP;

    RETURN;
END
$$;

/*
 *  Show Jobs By Status
 */
CREATE FUNCTION show_job_status(p_status text, int default 10) RETURNS SETOF job_log
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_list      job_log%ROWTYPE;
BEGIN
    FOR v_job_list IN SELECT job_id, owner, job_name, start_time, end_time, status, pid  
        FROM job_log
        WHERE status = p_status
        ORDER BY job_id DESC
        LIMIT $2
    LOOP
        RETURN NEXT v_job_list; 
    END LOOP;

    RETURN;
END
$$;

/*
 *  Show Jobs By Exact Name and Status
 */
CREATE FUNCTION show_job_status(p_name text, p_status text, int default 10) RETURNS SETOF job_log
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_list      job_log%ROWTYPE;
BEGIN
    FOR v_job_list IN SELECT job_id, owner, job_name, start_time, end_time, status, pid  
        FROM job_log
        WHERE job_name = upper(p_name)
        AND status = p_status
        ORDER BY job_id DESC
        LIMIT $3
    LOOP
        RETURN NEXT v_job_list; 
    END LOOP;

    RETURN;
END
$$;


/*
 *  Show Job Details By Job ID
 */
CREATE FUNCTION show_detail(p_id bigint) RETURNS SETOF job_detail
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_detail     job_detail%ROWTYPE;
BEGIN
    FOR v_job_detail IN SELECT job_id, step_id, action, start_time, end_time, elapsed_time, status, message
        FROM job_detail
        WHERE job_id = p_id
        ORDER BY step_id ASC
    LOOP
        RETURN NEXT v_job_detail; 
    END LOOP;

    RETURN;
END
$$;

/*
 *  Show Job Details By Exact Name
 */
CREATE FUNCTION show_detail(p_name text, int default 1) RETURNS SETOF job_detail
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_list      job_log%ROWTYPE;
    v_job_detail     job_detail%ROWTYPE;
BEGIN

    FOR v_job_list IN SELECT job_id, owner, job_name, start_time, end_time, status, pid  
        FROM job_log
        WHERE job_name = upper(p_name)
        ORDER BY job_id DESC
        LIMIT $2
    LOOP
        FOR v_job_detail IN SELECT job_id, step_id, action, start_time, end_time, elapsed_time, status, message
            FROM job_detail
            WHERE job_id = v_job_list.job_id
            ORDER BY step_id ASC
        LOOP
            RETURN NEXT v_job_detail; 
        END LOOP;
    END LOOP;

    RETURN;
END
$$;


/*
 *  Show Currently Running Jobs
 */
CREATE FUNCTION show_running(int default 10) RETURNS SETOF job_log
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_job_list      job_log%ROWTYPE;
BEGIN
    FOR v_job_list IN SELECT job_id, owner, job_name, start_time, end_time, status, pid  
        FROM job_log j
        JOIN pg_stat_activity p ON j.pid = p.procpid
        WHERE status IS NULL
        ORDER BY job_id DESC
        LIMIT $1
    LOOP
        RETURN NEXT v_job_list; 
    END LOOP;

    RETURN;
END
$$;
