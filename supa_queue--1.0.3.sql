CREATE TABLE job_queue (
    job_id BIGINT GENERATED BY DEFAULT AS IDENTITY,
    http_verb TEXT NOT NULL CHECK (http_verb IN ('GET', 'POST', 'DELETE')),
    payload jsonb,
    status TEXT NOT NULL DEFAULT '',
    retry_count INTEGER DEFAULT 0,
    retry_limit INTEGER DEFAULT 10,
    url_path TEXT DEFAULT '',
    content TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT job_id_pkey PRIMARY KEY (job_id)
);

CREATE TABLE current_jobs (
    request_id BIGINT NOT NULL,
    job_id BIGINT NOT NULL
);

CREATE TABLE workers (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY,
    locked BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT workers_pkey PRIMARY KEY (id)
);

do $$
begin
execute (
    select string_agg('INSERT INTO workers DEFAULT VALUES',';')
    from generate_series(1,5)
);
end;
$$;

--
-- Execute current jobs function if there are available workers
--
CREATE OR REPLACE FUNCTION process_current_jobs_if_unlocked()
RETURNS VOID AS $$
DECLARE
    worker RECORD;
BEGIN
    -- Find an unlocked worker
    SELECT * INTO worker FROM workers FOR UPDATE SKIP LOCKED LIMIT 1;
    IF worker IS NOT NULL THEN
        RAISE NOTICE 'Using worker_id: %', worker.id;
        -- Lock the worker (this is already done by the SELECT ... FOR UPDATE)

        -- Process current jobs
        PERFORM process_current_jobs();

        -- Unlock the worker
        UPDATE workers SET locked = FALSE WHERE id = worker.id;
    ELSE
        RAISE NOTICE 'No unlocked workers available';
    END IF;
END;
$$ LANGUAGE plpgsql;
--
-- Loop through records in current_jobs and get response from pg_net
--
CREATE OR REPLACE FUNCTION process_current_jobs()
RETURNS VOID
SECURITY DEFINER
SET search_path = public, extensions, net, vault
AS $$
DECLARE
    current_job RECORD;
    response_result RECORD;
BEGIN
    FOR current_job IN SELECT * FROM current_jobs
    FOR UPDATE SKIP LOCKED
    LOOP
        RAISE NOTICE 'Processing job_id: %, request_id: %', current_job.job_id, current_job.request_id;

        SELECT
            status,
            (response).status_code AS status_code,
            (response).body AS body
        INTO response_result
        FROM net._http_collect_response(current_job.request_id);

        IF response_result.status = 'SUCCESS' AND response_result.status_code BETWEEN 200 AND 299 THEN
            RAISE NOTICE 'Job completed (job_id: %)', current_job.job_id;

            UPDATE job_queue
            SET status = 'complete',
                content = response_result.body::TEXT
            WHERE job_id = current_job.job_id;

            DELETE FROM current_jobs
            WHERE request_id = current_job.request_id;
        ELSIF response_result.status = 'ERROR' THEN
            RAISE NOTICE 'Job failed (job_id: %)', current_job.job_id;

            UPDATE job_queue
            SET status = 'failed',
                retry_count = retry_count + 1
            WHERE job_id = current_job.job_id;

            DELETE FROM current_jobs
            WHERE request_id = current_job.request_id;
        ELSE
            RAISE NOTICE 'Job still in progress or not found (job_id: %)', current_job.job_id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

--
-- Called after a record is insert in the queue
--
CREATE OR REPLACE FUNCTION process_job()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, extensions, net, vault
AS $$
DECLARE
    request_id BIGINT;
    api_key TEXT;
    base_url TEXT;
    did_timeout BOOLEAN;
    response_message TEXT;
    response_status_code INTEGER;
BEGIN
    RAISE NOTICE 'Processing job_id: %', NEW.job_id;

    UPDATE job_queue
    SET status = 'processing'
    WHERE job_id = NEW.job_id;
    -- Get the API key
    SELECT decrypted_secret
    INTO api_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role';
    -- Get the consumer function URL
    SELECT decrypted_secret
    INTO base_url
    FROM vault.decrypted_secrets
    WHERE name = 'consumer_function';
    -- Call the request_wrapper to process the job
    request_id := request_wrapper(
        method := NEW.http_verb,
        url := base_url || COALESCE(NEW.url_path, ''),
        body := COALESCE(NEW.payload::jsonb, '{}'::jsonb),
        headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json')
    );

    INSERT INTO current_jobs (request_id, job_id)
    VALUES (request_id, NEW.job_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--
-- Convenience function around pg_net:
--
CREATE OR REPLACE FUNCTION request_wrapper(
    method TEXT,
    url TEXT,
    params JSONB DEFAULT '{}'::JSONB,
    body JSONB DEFAULT '{}'::JSONB,
    headers JSONB DEFAULT '{}'::JSONB
)
RETURNS BIGINT
SECURITY DEFINER
SET search_path = public, extensions, net
LANGUAGE plpgsql
AS $$
DECLARE
    request_id BIGINT;
    timeout INT;
BEGIN
    timeout := 6000;

    IF method = 'DELETE' THEN
        SELECT net.http_delete(
            url:=url,
            params:=params,
            headers:=headers,
            timeout_milliseconds:=timeout
        ) INTO request_id;
    ELSIF method = 'POST' THEN
        SELECT net.http_post(
            url:=url,
            body:=body,
            params:=params,
            headers:=headers,
            timeout_milliseconds:=timeout
        ) INTO request_id;
    ELSIF method = 'GET' THEN
        SELECT net.http_get(
            url:=url,
            params:=params,
            headers:=headers,
            timeout_milliseconds:=timeout
        ) INTO request_id;
    ELSE
        RAISE EXCEPTION 'Method must be DELETE, POST, or GET';
    END IF;

    RETURN request_id;
END;
$$;

--
-- Retrying jobs flagged as failures to increase reliability
--
CREATE OR REPLACE FUNCTION public.retry_failed_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'net', 'vault'
AS $function$
DECLARE
    r RECORD;
    request_id BIGINT;
    api_key TEXT;
    base_url TEXT;
    response_result net._http_response_result;
BEGIN
    RAISE NOTICE 'Retrying failed jobs';

    -- Get the API key
    SELECT decrypted_secret
    INTO api_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role';

    FOR r IN (
            SELECT * FROM job_queue
            WHERE (status = 'failed' AND retry_count < retry_limit)
              OR (status = 'processing' AND created_at < current_timestamp - INTERVAL '10 minutes')
            FOR UPDATE SKIP LOCKED
        ) LOOP
            RAISE NOTICE 'Retrying job_id: %', r.job_id;

        UPDATE job_queue
        SET retry_count = retry_count + 1
        WHERE job_id = r.job_id;

        SELECT decrypted_secret
        INTO base_url
        FROM vault.decrypted_secrets
        WHERE name = 'consumer_function';
        -- Call the request_wrapper to process the job
        request_id := request_wrapper(
            method := r.http_verb,
            -- Edge function call (like AWS lambda)
            url := base_url || COALESCE(r.url_path, ''),
            body := COALESCE(r.payload::jsonb, '{}'::jsonb),
            headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json')
        );
        INSERT INTO current_jobs (request_id, job_id)
        VALUES (request_id, r.job_id);
    END LOOP;
END;
$function$;

-- Adding the trigger to the queue table:
CREATE TRIGGER process_job_trigger
AFTER INSERT ON job_queue
FOR EACH ROW
EXECUTE FUNCTION process_job();

CREATE OR REPLACE FUNCTION public.process_tasks_subminute()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'secrets', 'net'
AS $function$
BEGIN
  -- Call process_tasks() with 20 seconds between each call
  PERFORM process_current_jobs_if_unlocked();
  PERFORM pg_sleep(20);
  PERFORM process_current_jobs_if_unlocked();
  PERFORM pg_sleep(20);
  PERFORM process_current_jobs_if_unlocked();
  return 'Done';
END;
$function$;

-- Retry jobs each 10 minutes
SELECT cron.schedule(
    'retry_failed_jobs',
    '*/10 * * * *',
    $$ SELECT retry_failed_jobs(); $$
);
-- Schedule process jobs 3 times per minute:
SELECT cron.schedule(
    'process_tasks_subminute',
    '* * * * *',
    $$ SELECT process_tasks_subminute(); $$
);

ALTER TABLE current_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE job_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE workers ENABLE ROW LEVEL SECURITY;