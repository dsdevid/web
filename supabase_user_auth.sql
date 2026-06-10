-- ============================================================
-- 학생 사용자 접속(세션) 시스템 — Supabase SQL Editor에서 실행
-- 기준: 기능명세서 user_master/sessions/logs + 세션 처리 3종 프롬프트
--
-- [스택 변환]  스펙은 Cloudflare Workers + bcryptjs 기준이나,
--   이 프로젝트는 브라우저 → Supabase RPC(SECURITY DEFINER) 직접 호출 구조.
--   따라서 createSession/validateSession/completeFirstLogin 을
--   Postgres RPC 함수로 변환하고, 해싱은 pgcrypto crypt()/gen_salt('bf',10) 사용.
--
-- [명명 변환]  기존 admin_master snake_case 규칙에 맞춤.
--   mst_users         (UUID, PK)
--   mst_id            (학번, UNIQUE)
--   mst_password      → mst_passwd_hash
--   mst_lastLoginAt   → mst_last_login_at
--   mst_isFirstLogin  → mst_is_first_login
--   ses_sessionId     → ses_session_id   (이하 동일 규칙)
--   log_logId         → log_id
--
-- [보안 조정]  anon 공개키로 브라우저에서 직접 호출되는 구조이므로:
--   - complete_first_login: 스펙의 userId 인자 → temp 세션 토큰 기반으로 변경
--     (userId만 받으면 누구나 타인 비밀번호 변경 가능 → 차단)
--   - create_session: anon 권한 미부여(내부 호출 전용). 직접 호출 시 세션 위조 방지.
--
-- 실행 순서: 1) pgcrypto → 2) 테이블 → 3) 함수 → 4) 권한
-- ============================================================

-- 1. pgcrypto (gen_random_uuid / crypt / gen_salt)
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ============================================================
-- 2. 테이블
-- ============================================================

-- 2-1. user_master (학생 마스터)
CREATE TABLE IF NOT EXISTS user_master (
  mst_users          uuid        NOT NULL DEFAULT gen_random_uuid(),
  mst_id             text        NOT NULL,                         -- 학번 (로그인 ID)
  mst_ban            text,
  mst_prt            text,
  mst_sex            text,
  mst_name           text,
  mst_lnce           text,
  mst_is_first_login   text        NOT NULL DEFAULT 'Y'            -- DB 소유 (초기암호 여부)
                       CHECK (mst_is_first_login IN ('Y', 'N')),
  mst_passwd_hash      text,                                       -- DB 소유 (bcrypt 해시, 원문 미저장)
  mst_last_login_at    timestamptz,                                -- DB 소유 (last 접속일시)
  mst_login_fail_count smallint    NOT NULL DEFAULT 0,             -- DB 소유 (로그인 실패 카운트)
  mst_locked_until     timestamptz,                                -- DB 소유 (null = 잠금 없음)

  CONSTRAINT user_master_pkey    PRIMARY KEY (mst_users),
  CONSTRAINT user_master_id_uniq UNIQUE (mst_id)                   -- 학번 중복 방지 (UNIQUE가 인덱스 겸함)
);


-- 2-2. sessions (세션 토큰)
CREATE TABLE IF NOT EXISTS sessions (
  ses_session_id  text        NOT NULL,
  ses_user_id     uuid        NOT NULL,
  ses_created_at  timestamptz NOT NULL DEFAULT now(),
  ses_expires_at  timestamptz NOT NULL,
  ses_ip_address  text,
  ses_role        text        NOT NULL CHECK (ses_role IN ('temp', 'active')),

  CONSTRAINT sessions_pkey        PRIMARY KEY (ses_session_id),
  CONSTRAINT sessions_user_uniq   UNIQUE (ses_user_id),            -- 동일 사용자 중복 세션 차단
  CONSTRAINT sessions_user_fkey   FOREIGN KEY (ses_user_id)
                                  REFERENCES user_master (mst_users) ON DELETE CASCADE
);
-- 참고: ses_expires_at > now() CHECK 제약은 now()가 immutable이 아니라 불가.
--       만료 검증은 validate_session 함수에서 처리.


-- 2-3. logs (접속 로그)
CREATE TABLE IF NOT EXISTS logs (
  log_id        bigint      GENERATED ALWAYS AS IDENTITY,
  log_user_id   uuid,
  log_action    text        NOT NULL
                CHECK (log_action IN ('login', 'logout', 'access', 'first_login', 'change_password')),
  log_timestamp timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT logs_pkey      PRIMARY KEY (log_id),
  CONSTRAINT logs_user_fkey FOREIGN KEY (log_user_id)
                            REFERENCES user_master (mst_users) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_logs_user ON logs (log_user_id);


-- ============================================================
-- 3. 함수
-- ============================================================

-- 3-1. create_session — 세션 생성 (중복 방지 포함). 내부 호출 전용(anon 미부여).
--   [프롬프트 1] 변환. isFirstLogin = 'Y' → temp(30분), 'N' → active(2시간).
CREATE OR REPLACE FUNCTION create_session(
  p_user_id        uuid,
  p_is_first_login text,
  p_ip_address     text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_session_id text := gen_random_uuid()::text;
  v_role       text;
  v_expires    timestamptz;
BEGIN
  -- 0) 만료 세션 전역 청소 + logs 2일 초과분 삭제 (기회적)
  DELETE FROM sessions WHERE ses_expires_at < now();
  DELETE FROM logs     WHERE log_timestamp  < now() - interval '2 days';

  -- 1) 기존 세션 삭제 (중복 접속 방지)
  DELETE FROM sessions WHERE ses_user_id = p_user_id;

  -- 2) 세션 유형 결정
  IF p_is_first_login = 'Y' THEN
    v_role    := 'temp';
    v_expires := now() + interval '30 minutes';
  ELSE
    v_role    := 'active';
    v_expires := now() + interval '15 minutes';
  END IF;

  -- 3) 신규 세션 발급
  INSERT INTO sessions (ses_session_id, ses_user_id, ses_created_at, ses_expires_at, ses_ip_address, ses_role)
  VALUES (v_session_id, p_user_id, now(), v_expires, COALESCE(p_ip_address, ''), v_role);

  RETURN v_session_id;
END;
$$;


-- 3-2. process_student_login — 학번 + 비밀번호 로그인 → 세션 발급
--   (무비밀번호 방식 process_student_login(p_student_id, p_student_name) 완전 교체)
--   파라미터명 변경 → CREATE OR REPLACE 불가 → 기존 함수 DROP 후 재생성.
DROP FUNCTION IF EXISTS process_student_login(text, text);

CREATE OR REPLACE FUNCTION process_student_login(
  p_student_id text,
  p_password   text,
  p_ip_address text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user       user_master%ROWTYPE;
  v_session_id text;
  v_ok         boolean;
BEGIN
  SELECT * INTO v_user FROM user_master WHERE mst_id = p_student_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  -- 잠금 확인 (5회 실패 시 30분 잠금)
  IF v_user.mst_locked_until IS NOT NULL AND v_user.mst_locked_until > now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'LOCKED',
      'locked_until', v_user.mst_locked_until);
  END IF;

  -- 비밀번호 검증
  IF v_user.mst_passwd_hash IS NULL THEN
    -- 임시비번 미설정(신규 동기화 상태): 최초 로그인 + 입력값이 학번이면 통과
    v_ok := (v_user.mst_is_first_login = 'Y' AND p_password = v_user.mst_id);
  ELSE
    -- bcrypt 비교 (복호화 불가, 재해싱 후 비교)
    v_ok := (v_user.mst_passwd_hash = crypt(p_password, v_user.mst_passwd_hash));
  END IF;

  IF NOT v_ok THEN
    -- 실패 카운트 증가 + 5회 도달 시 30분 잠금
    UPDATE user_master SET
      mst_login_fail_count = mst_login_fail_count + 1,
      mst_locked_until = CASE
        WHEN mst_login_fail_count + 1 >= 5 THEN now() + interval '30 minutes'
        ELSE mst_locked_until
      END
    WHERE mst_users = v_user.mst_users;
    RETURN jsonb_build_object('success', false, 'error', 'WRONG_PASSWORD');
  END IF;

  -- 세션 발급 (temp/active는 최초 로그인 여부로 결정)
  v_session_id := create_session(v_user.mst_users, v_user.mst_is_first_login, p_ip_address);

  -- 성공: 실패 카운트·잠금 초기화 (last_login_at은 최초 로그인이 아닐 때만 갱신)
  UPDATE user_master SET
    mst_login_fail_count = 0,
    mst_locked_until     = NULL,
    mst_last_login_at    = CASE WHEN v_user.mst_is_first_login = 'N' THEN now() ELSE mst_last_login_at END
  WHERE mst_users = v_user.mst_users;

  INSERT INTO logs (log_user_id, log_action) VALUES (v_user.mst_users, 'login');

  RETURN jsonb_build_object(
    'success',        true,
    'session_id',     v_session_id,
    'role',           CASE WHEN v_user.mst_is_first_login = 'Y' THEN 'temp' ELSE 'active' END,
    'is_first_login', v_user.mst_is_first_login,
    'student_id',     v_user.mst_id,
    'student_name',   v_user.mst_name,
    'student_ban',    v_user.mst_ban,
    'student_prt',    v_user.mst_prt
  );
END;
$$;


-- 3-3. validate_session — 세션 유효성 검사
--   [프롬프트 2] 변환.
CREATE OR REPLACE FUNCTION validate_session(p_session_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ses sessions%ROWTYPE;
BEGIN
  -- 만료 세션 전역 청소 (본인 토큰 제외 — 본인 만료는 아래에서 EXPIRED 처리)
  DELETE FROM sessions WHERE ses_expires_at < now() AND ses_session_id <> p_session_id;
  -- logs 2일 초과분 삭제 (기회적)
  DELETE FROM logs WHERE log_timestamp < now() - interval '2 days';

  SELECT * INTO v_ses FROM sessions WHERE ses_session_id = p_session_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'NO_SESSION');
  END IF;

  IF v_ses.ses_expires_at <= now() THEN
    DELETE FROM sessions WHERE ses_session_id = p_session_id;
    RETURN jsonb_build_object('valid', false, 'reason', 'EXPIRED');
  END IF;

  RETURN jsonb_build_object(
    'valid',   true,
    'role',    v_ses.ses_role,
    'user_id', v_ses.ses_user_id
  );
END;
$$;


-- 3-4. complete_first_login — 최초 비밀번호 변경 완료
--   [프롬프트 3] 변환 + 보안 조정: userId 대신 temp 세션 토큰으로 본인 확인.
CREATE OR REPLACE FUNCTION complete_first_login(
  p_session_id   text,
  p_new_password text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ses sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_ses FROM sessions WHERE ses_session_id = p_session_id;

  IF NOT FOUND OR v_ses.ses_expires_at <= now() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'INVALID_SESSION');
  END IF;

  IF v_ses.ses_role != 'temp' THEN
    RETURN jsonb_build_object('success', false, 'reason', 'NOT_TEMP_SESSION');
  END IF;

  -- 비밀번호 갱신 + 최초로그인 해제 + 마지막 로그인 갱신
  UPDATE user_master SET
    mst_passwd_hash    = crypt(p_new_password, gen_salt('bf', 10)),
    mst_is_first_login = 'N',
    mst_last_login_at  = now()
  WHERE mst_users = v_ses.ses_user_id;

  -- temp 세션 삭제 (재로그인 유도)
  DELETE FROM sessions WHERE ses_session_id = p_session_id;

  INSERT INTO logs (log_user_id, log_action) VALUES (v_ses.ses_user_id, 'first_login');

  RETURN jsonb_build_object('success', true);
END;
$$;


-- 3-5. logout_session — 로그아웃 (세션 삭제 + 로그)
CREATE OR REPLACE FUNCTION logout_session(p_session_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT ses_user_id INTO v_user_id FROM sessions WHERE ses_session_id = p_session_id;
  DELETE FROM sessions WHERE ses_session_id = p_session_id;

  IF v_user_id IS NOT NULL THEN
    INSERT INTO logs (log_user_id, log_action) VALUES (v_user_id, 'logout');
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;


-- 3-5b. change_student_password — 로그인 상태 자발적 비밀번호 변경
--   active 세션 + 기존 비밀번호 검증 후 갱신. 현재 세션은 유지.
--   보안: 기존비번 5회 오류 시 30분 잠금(무차별 대입 차단),
--         변경 성공 시 다른 세션 전부 무효화(탈취 세션 강제 종료).
CREATE OR REPLACE FUNCTION change_student_password(
  p_session_id   text,
  p_old_password text,
  p_new_password text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ses  sessions%ROWTYPE;
  v_user user_master%ROWTYPE;
BEGIN
  SELECT * INTO v_ses FROM sessions WHERE ses_session_id = p_session_id;
  IF NOT FOUND OR v_ses.ses_expires_at <= now() OR v_ses.ses_role <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION');
  END IF;

  SELECT * INTO v_user FROM user_master WHERE mst_users = v_ses.ses_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION');
  END IF;

  -- 잠금 확인 (무차별 대입 차단)
  IF v_user.mst_locked_until IS NOT NULL AND v_user.mst_locked_until > now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'LOCKED',
      'locked_until', v_user.mst_locked_until);
  END IF;

  -- 기존 비밀번호 검증 (오류 시 실패 카운트 증가 + 5회 도달 시 30분 잠금)
  IF v_user.mst_passwd_hash IS NULL
     OR v_user.mst_passwd_hash <> crypt(p_old_password, v_user.mst_passwd_hash) THEN
    UPDATE user_master SET
      mst_login_fail_count = mst_login_fail_count + 1,
      mst_locked_until = CASE
        WHEN mst_login_fail_count + 1 >= 5 THEN now() + interval '30 minutes'
        ELSE mst_locked_until
      END
    WHERE mst_users = v_user.mst_users;
    RETURN jsonb_build_object('success', false, 'error', 'WRONG_PASSWORD');
  END IF;

  IF length(p_new_password) < 4 THEN
    RETURN jsonb_build_object('success', false, 'error', 'TOO_SHORT');
  END IF;

  -- 변경 + 실패 카운트/잠금 초기화
  UPDATE user_master SET
    mst_passwd_hash      = crypt(p_new_password, gen_salt('bf', 10)),
    mst_login_fail_count = 0,
    mst_locked_until     = NULL
  WHERE mst_users = v_user.mst_users;

  -- 다른 세션 무효화 (현재 세션만 유지 → 탈취된 타 세션 강제 종료)
  DELETE FROM sessions WHERE ses_user_id = v_user.mst_users AND ses_session_id <> p_session_id;

  INSERT INTO logs (log_user_id, log_action) VALUES (v_user.mst_users, 'change_password');

  RETURN jsonb_build_object('success', true);
END;
$$;


-- 3-6. admin_reset_student_password — 관리자가 학생 임시 비밀번호 개별 지정
--   기존 admin RPC 패턴(p_admin_id 로 admin_master 확인) 동일.
--   지정 후 mst_is_first_login='Y' → 학생 첫 로그인 시 변경 강제.
DROP FUNCTION IF EXISTS admin_reset_student_password(text, text, text);
CREATE FUNCTION admin_reset_student_password(
  p_session_token text,
  p_student_id    text,
  p_temp_password text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin admin_master%ROWTYPE;
  v_users uuid;
BEGIN
  v_admin := _admin_session(p_session_token);
  IF v_admin.admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  UPDATE user_master SET
    mst_passwd_hash      = crypt(p_temp_password, gen_salt('bf', 10)),
    mst_is_first_login   = 'Y',
    mst_login_fail_count = 0,
    mst_locked_until     = NULL          -- 초기화 시 잠금도 해제
  WHERE mst_id = p_student_id
  RETURNING mst_users INTO v_users;

  IF v_users IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  -- 비밀번호 변경 시 기존 세션 무효화
  DELETE FROM sessions WHERE ses_user_id = v_users;

  RETURN jsonb_build_object('success', true);
END;
$$;


-- 3-7. sync_students — 구글시트 전체 학생목록 동기화 (GAS → service_role 호출)
--   컬럼 소유권 분리:
--     시트 소유: mst_id, mst_name, mst_ban, mst_prt, mst_sex, mst_lnce
--     DB  소유: mst_passwd_hash, mst_last_login_at, mst_is_first_login,
--               mst_login_fail_count, mst_locked_until  (동기화 시 보존)
--   처리:
--     신규 학번 → INSERT (해시 없음 mst_passwd_hash=NULL, is_first_login='Y')
--                 → 첫 로그인 시 학번을 임시비번으로 사용 (process_student_login 참조)
--                 → 대량 bcrypt 회피 (1221건 timeout 방지)
--     기존 학번 → UPDATE (시트 소유 컬럼만, DB 소유 컬럼 보존)
--     빠진 학번 → 완전 삭제 (sessions CASCADE, logs SET NULL)
--   ※ anon 미부여 — GAS service_role 전용 (anon 부여 시 누구나 학생 일괄 변경/삭제 가능)
CREATE OR REPLACE FUNCTION sync_students(p_students jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ids      text[];
  v_inserted int := 0;
  v_updated  int := 0;
  v_deleted  int := 0;
BEGIN
  -- 들어온 학번 목록
  SELECT array_agg(s->>'mst_id') INTO v_ids
  FROM jsonb_array_elements(p_students) s;

  -- 빈 배열 방어: 전송 데이터가 없으면 삭제 방지 위해 중단
  IF v_ids IS NULL OR array_length(v_ids, 1) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY');
  END IF;

  -- upsert (신규는 해시 없이 INSERT, is_first_login='Y' — 첫 로그인 시 학번이 임시비번)
  WITH up AS (
    INSERT INTO user_master (mst_id, mst_name, mst_ban, mst_prt, mst_sex, mst_lnce,
                             mst_is_first_login)
    SELECT s->>'mst_id', s->>'mst_name', s->>'mst_ban', s->>'mst_prt', s->>'mst_sex', s->>'mst_lnce',
           'Y'
    FROM jsonb_array_elements(p_students) s
    ON CONFLICT (mst_id) DO UPDATE SET
      mst_name = EXCLUDED.mst_name,
      mst_ban  = EXCLUDED.mst_ban,
      mst_prt  = EXCLUDED.mst_prt,
      mst_sex  = EXCLUDED.mst_sex,
      mst_lnce = EXCLUDED.mst_lnce
      -- 비번/접속일시/최초로그인/잠금 컬럼은 갱신하지 않음 (보존)
    RETURNING (xmax = 0) AS inserted
  )
  SELECT
    count(*) FILTER (WHERE inserted),
    count(*) FILTER (WHERE NOT inserted)
  INTO v_inserted, v_updated
  FROM up;

  -- 시트에서 빠진 학번 완전 삭제
  WITH del AS (
    DELETE FROM user_master WHERE NOT (mst_id = ANY(v_ids)) RETURNING 1
  )
  SELECT count(*) INTO v_deleted FROM del;

  RETURN jsonb_build_object(
    'success',  true,
    'inserted', v_inserted,
    'updated',  v_updated,
    'deleted',  v_deleted
  );
END;
$$;


-- ============================================================
-- 4. 권한 (브라우저 anon 직접 호출)
--   create_session / sync_students 는 의도적으로 미부여
--     (create_session: 내부 호출 전용 — 세션 위조 방지)
--     (sync_students : GAS service_role 전용 — 학생 일괄 변경/삭제 차단)
-- ============================================================
GRANT EXECUTE ON FUNCTION process_student_login(text, text, text)        TO anon;
GRANT EXECUTE ON FUNCTION validate_session(text)                         TO anon;
GRANT EXECUTE ON FUNCTION complete_first_login(text, text)               TO anon;
GRANT EXECUTE ON FUNCTION change_student_password(text, text, text)      TO anon;
GRANT EXECUTE ON FUNCTION logout_session(text)                           TO anon;
GRANT EXECUTE ON FUNCTION admin_reset_student_password(text, text, text) TO anon;
