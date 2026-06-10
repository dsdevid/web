-- ============================================================
-- Supabase SQL Editor에서 실행
-- 순서: 1) pgcrypto 활성화 → 2) 테이블 생성 → 3) 슈퍼관리자 등록
-- ============================================================

-- 1. pgcrypto 확장 활성화 (비밀번호 bcrypt 해싱용)
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- 2. admin_master 테이블 생성
CREATE TABLE IF NOT EXISTS admin_master (
  admin_is_super_admin      boolean        NOT NULL DEFAULT false,
  admin_id                  text           NOT NULL,
  admin_email               text           NOT NULL,
  admin_name                text           NOT NULL,
  admin_passwd_hash         VARCHAR(255),
  admin_passwd_changed_at   timestamptz,
  admin_login_fail_count    smallint       NOT NULL DEFAULT 0,
  admin_locked_until        timestamptz,                          -- null = 잠금 없음
  admin_status              text           NOT NULL DEFAULT 'active'
                            CHECK (admin_status IN ('active', 'inactive', 'locked')),
  admin_last_login_at       timestamptz,
  admin_session_expires_at  timestamptz,
  admin_created_at          timestamptz    NOT NULL DEFAULT now(),
  admin_created_by          text,
  admin_updated_at          timestamptz,
  admin_updated_by          text,

  CONSTRAINT admin_master_pkey        PRIMARY KEY (admin_id),
  CONSTRAINT admin_master_email_uniq  UNIQUE (admin_email)
);

-- 세션 토큰 컬럼 (단일 세션 = 계정당 토큰 1개)
ALTER TABLE admin_master
  ADD COLUMN IF NOT EXISTS admin_session_token text;

-- 인덱스 (로그인 시 email로 조회)
CREATE INDEX IF NOT EXISTS idx_admin_email  ON admin_master (admin_email);
CREATE INDEX IF NOT EXISTS idx_admin_status ON admin_master (admin_status);
CREATE INDEX IF NOT EXISTS idx_admin_token  ON admin_master (admin_session_token);


-- 3. 슈퍼관리자 최초 등록
--    이미 존재하면 건너뜀 (ON CONFLICT DO NOTHING)
INSERT INTO admin_master (
  admin_is_super_admin,
  admin_id,
  admin_email,
  admin_name,
  admin_status,
  admin_created_at,
  admin_created_by
) VALUES (
  true,
  'super_admin_01',
  'go.auth01@gmail.com',
  '슈퍼관리자',
  'active',
  now(),
  'system_init'
) ON CONFLICT (admin_email) DO NOTHING;


-- 4. 등록 결과 확인
SELECT
  admin_id,
  admin_email,
  admin_name,
  admin_is_super_admin,
  admin_status,
  admin_created_at
FROM admin_master
ORDER BY admin_created_at;


-- ============================================================
-- 5. 슈퍼관리자 비밀번호 설정
--    ★ 원하는 비밀번호로 변경 후 실행
--    bcrypt 해싱 저장 — 원문은 DB에 저장되지 않음
-- ============================================================
UPDATE admin_master
SET
  admin_passwd_hash       = crypt('여기에_비밀번호_입력', gen_salt('bf')),
  admin_passwd_changed_at = now()
WHERE admin_id = 'super_admin_01';

-- 설정 확인 (hash 앞 7자리만 표시)
SELECT admin_id, admin_name, left(admin_passwd_hash, 7) AS hash_prefix
FROM admin_master WHERE admin_id = 'super_admin_01';


-- ============================================================
-- 6. 로그인 처리 RPC 함수
--    GAS → Supabase RPC 호출로 비밀번호 비교 + 실패 카운트 관리
--    bcrypt 비교: crypt(입력값, 저장된_hash) = 저장된_hash
-- ============================================================
-- ============================================================
-- 7. 학생 로그인 RPC
--    ★ 무비밀번호(학번+이름) 버전 폐기 — supabase_user_auth.sql 의
--      비밀번호(bcrypt) 버전 process_student_login(text,text,text) 사용.
--      레거시 2-arg 가 남아 있으면 PII 열거 위험 → 명시적으로 제거.
-- ============================================================
DROP FUNCTION IF EXISTS process_student_login(text, text);


-- ============================================================
-- 10. 공지사항 DB 연동 (Supabase SQL Editor에서 실행)
-- ============================================================

-- 고정 컬럼 추가 (이미 있으면 무시)
ALTER TABLE user_textnotice
  ADD COLUMN IF NOT EXISTS textnotice_pin boolean NOT NULL DEFAULT false;

-- 공개 공지 "목록" 조회 (anon — 메타만, 본문 제외, 최신 100건, 고정 우선)
CREATE OR REPLACE FUNCTION get_notices_public()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) FROM (
    SELECT textnotice_id, textnotice_date, textnotice_title, textnotice_pin
    FROM user_textnotice
    WHERE textnotice_hidden = false
    ORDER BY textnotice_pin DESC, textnotice_date DESC
    LIMIT 100
  ) n);
END;$$;
GRANT EXECUTE ON FUNCTION get_notices_public() TO anon;

-- 공개 공지 "상세" 1건 조회 (anon — 클릭 시 본문 로드, 없거나 비공개면 null)
CREATE OR REPLACE FUNCTION get_notice_detail(p_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r jsonb;
BEGIN
  SELECT to_jsonb(n) INTO r FROM (
    SELECT textnotice_id, textnotice_date, textnotice_owner,
           textnotice_title, textnotice_body, textnotice_readcnt
    FROM user_textnotice
    WHERE textnotice_id = p_id AND textnotice_hidden = false
  ) n;
  RETURN r;  -- 없으면 null
END;$$;
GRANT EXECUTE ON FUNCTION get_notice_detail(integer) TO anon;

-- 관리자 공지 조회 (전체, 숨김 포함)
DROP FUNCTION IF EXISTS get_notices_admin(text);
CREATE FUNCTION get_notices_admin(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('error','UNAUTHORIZED'); END IF;
  RETURN (SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) FROM (
    SELECT textnotice_id, textnotice_date, textnotice_owner,
           textnotice_title, textnotice_body, textnotice_readcnt,
           textnotice_hidden, textnotice_pin
    FROM user_textnotice
    ORDER BY textnotice_pin DESC, textnotice_date DESC
    LIMIT 200
  ) n);
END;$$;
GRANT EXECUTE ON FUNCTION get_notices_admin(text) TO anon;

-- 조회수 증가 (anon 호출 가능 — 관리자 제외는 클라이언트에서 처리)
CREATE OR REPLACE FUNCTION increment_notice_readcnt(p_id integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE user_textnotice SET textnotice_readcnt = textnotice_readcnt + 1
  WHERE textnotice_id = p_id AND textnotice_hidden = false;
END;$$;
GRANT EXECUTE ON FUNCTION increment_notice_readcnt(integer) TO anon;

-- 공지 등록/수정 (p_id=0이면 INSERT, 아니면 UPDATE)
DROP FUNCTION IF EXISTS save_notice(text,integer,text,text,text,boolean,boolean);
CREATE FUNCTION save_notice(
  p_session_token text, p_id integer,
  p_title text, p_body text, p_owner text,
  p_hidden boolean, p_pin boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE; v_id integer;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED'); END IF;
  IF p_id IS NULL OR p_id = 0 THEN
    INSERT INTO user_textnotice(textnotice_date,textnotice_owner,textnotice_title,
      textnotice_body,textnotice_readcnt,textnotice_hidden,textnotice_pin)
    VALUES(now(),p_owner,p_title,p_body,0,p_hidden,p_pin)
    RETURNING textnotice_id INTO v_id;
  ELSE
    UPDATE user_textnotice SET
      textnotice_owner=p_owner, textnotice_title=p_title, textnotice_body=p_body,
      textnotice_hidden=p_hidden, textnotice_pin=p_pin
    WHERE textnotice_id=p_id;
    v_id := p_id;
  END IF;
  RETURN jsonb_build_object('success',true,'id',v_id);
END;$$;
GRANT EXECUTE ON FUNCTION save_notice(text,integer,text,text,text,boolean,boolean) TO anon;

-- 공지 삭제
DROP FUNCTION IF EXISTS delete_notice(text,integer);
CREATE FUNCTION delete_notice(p_session_token text, p_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED'); END IF;
  DELETE FROM user_textnotice WHERE textnotice_id = p_id;
  RETURN jsonb_build_object('success',true);
END;$$;
GRANT EXECUTE ON FUNCTION delete_notice(text,integer) TO anon;


-- ============================================================
-- 8. anon 권한 부여 (브라우저에서 직접 호출용)
--    Supabase Dashboard → Settings → API → anon public key 사용
-- ============================================================
GRANT EXECUTE ON FUNCTION process_admin_login(text, text)  TO anon;
-- process_student_login GRANT 은 supabase_user_auth.sql(비번 3-arg 버전)에서 부여

-- user_textnotice: 게시된 공지만 anon 조회 허용
ALTER TABLE user_textnotice ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon_read_published" ON user_textnotice;
CREATE POLICY "anon_read_published" ON user_textnotice
  FOR SELECT TO anon USING (textnotice_hidden = false);


-- ============================================================
-- 9. 관리자 대시보드 데이터 RPC
--    admin_id 확인 후 대시보드 데이터 반환 (SECURITY DEFINER = RLS 우회)
-- ============================================================
DROP FUNCTION IF EXISTS get_admin_dashboard_data(text);
CREATE FUNCTION get_admin_dashboard_data(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin      admin_master%ROWTYPE;
  v_today      timestamptz;
  v_today_cnt  int;
  v_notices    jsonb;
  v_adm_logs   jsonb;
  v_result     jsonb;
BEGIN
  v_admin := _admin_session(p_session_token);
  IF v_admin.admin_id IS NULL THEN
    RETURN jsonb_build_object('error', 'UNAUTHORIZED');
  END IF;

  v_today := date_trunc('day', now() AT TIME ZONE 'Asia/Seoul') AT TIME ZONE 'Asia/Seoul';

  SELECT count(*)::int INTO v_today_cnt FROM user_textnotice
  WHERE textnotice_date >= v_today;

  SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) INTO v_notices FROM (
    SELECT textnotice_id, textnotice_title, textnotice_date, textnotice_readcnt, textnotice_hidden
    FROM user_textnotice ORDER BY textnotice_date DESC LIMIT 5
  ) n;

  v_result := jsonb_build_object(
    'today_count', v_today_cnt,
    'notices',     v_notices
  );

  IF v_admin.admin_is_super_admin THEN
    SELECT COALESCE(jsonb_agg(a), '[]'::jsonb) INTO v_adm_logs FROM (
      SELECT admin_name, admin_email, admin_last_login_at, admin_is_super_admin
      FROM admin_master ORDER BY admin_last_login_at DESC NULLS LAST LIMIT 5
    ) a;
    v_result := v_result || jsonb_build_object('admin_logins', v_adm_logs);
  END IF;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_admin_dashboard_data(text) TO anon;


-- ============================================================
-- 6. 관리자 로그인 처리 RPC
-- ============================================================
CREATE OR REPLACE FUNCTION process_admin_login(p_admin_id text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin admin_master%ROWTYPE;
  v_token text;
BEGIN
  -- 계정 조회
  SELECT * INTO v_admin FROM admin_master WHERE admin_id = p_admin_id;

  IF NOT FOUND THEN
    -- 계정 열거 방지: 존재/비번오류/미설정/비활성 모두 동일 코드
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_FAILED');
  END IF;

  -- 잠금 확인 (자동 해제 포함)
  IF v_admin.admin_status = 'locked' THEN
    IF v_admin.admin_locked_until IS NOT NULL AND v_admin.admin_locked_until > now() THEN
      RETURN jsonb_build_object('success', false, 'error', 'LOCKED',
        'locked_until', v_admin.admin_locked_until);
    ELSE
      -- 잠금 기간 경과 → 자동 해제
      UPDATE admin_master
      SET admin_status = 'active', admin_locked_until = NULL, admin_login_fail_count = 0
      WHERE admin_id = p_admin_id;
      v_admin.admin_status := 'active';
    END IF;
  END IF;

  IF v_admin.admin_status = 'inactive' THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_FAILED');
  END IF;

  -- 비밀번호 미설정 확인
  IF v_admin.admin_passwd_hash IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'AUTH_FAILED');
  END IF;

  -- 비밀번호 비교 (bcrypt: 복호화 불가, 재해싱 후 비교)
  IF v_admin.admin_passwd_hash != crypt(p_password, v_admin.admin_passwd_hash) THEN
    -- 실패 카운트 증가 + 5회 초과 시 잠금
    UPDATE admin_master
    SET
      admin_login_fail_count = admin_login_fail_count + 1,
      admin_status = CASE
        WHEN admin_login_fail_count + 1 >= 5 THEN 'locked'
        ELSE admin_status
      END,
      admin_locked_until = CASE
        WHEN admin_login_fail_count + 1 >= 5 THEN now() + interval '30 minutes'
        ELSE admin_locked_until
      END
    WHERE admin_id = p_admin_id;

    RETURN jsonb_build_object('success', false, 'error', 'AUTH_FAILED');
  END IF;

  -- 활성 세션 검사: 같은 계정이 이미 접속 중이면 신규 차단
  IF v_admin.admin_session_expires_at IS NOT NULL
     AND v_admin.admin_session_expires_at > now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALREADY_ACTIVE');
  END IF;

  -- 로그인 성공: 토큰 발급 + 실패 카운트 초기화 + 마지막 로그인 갱신
  v_token := gen_random_uuid()::text;
  UPDATE admin_master
  SET
    admin_login_fail_count   = 0,
    admin_last_login_at      = now(),
    admin_session_token      = v_token,
    admin_session_expires_at = now() + interval '6 minutes'
  WHERE admin_id = p_admin_id;

  RETURN jsonb_build_object(
    'success',              true,
    'session_token',        v_token,
    'admin_id',             v_admin.admin_id,
    'admin_name',           v_admin.admin_name,
    'admin_is_super_admin', v_admin.admin_is_super_admin
  );
END;
$$;


-- ============================================================
-- 6-1. 관리자 세션 검증 (내부 전용 — anon 비공개)
--   토큰 유효 + 미만료 + active → 만료시각 6분 슬라이딩 갱신 후 행 반환.
--   무효 시 admin_id 가 NULL 인 빈 행 반환.
-- ============================================================
CREATE OR REPLACE FUNCTION _admin_session(p_session_token text)
RETURNS admin_master
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  IF p_session_token IS NULL THEN RETURN v; END IF;
  UPDATE admin_master
  SET admin_session_expires_at = now() + interval '6 minutes'
  WHERE admin_session_token = p_session_token
    AND admin_session_expires_at > now()
    AND admin_status = 'active'
  RETURNING * INTO v;
  RETURN v;
END;
$$;

REVOKE EXECUTE ON FUNCTION _admin_session(text) FROM PUBLIC, anon;


-- ============================================================
-- 6-2. 관리자 세션 연장 (활동 갱신) — 클라 활동 시 throttle 호출
-- ============================================================
DROP FUNCTION IF EXISTS touch_admin_session(text);
CREATE FUNCTION touch_admin_session(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  v := _admin_session(p_session_token);
  RETURN jsonb_build_object('success', v.admin_id IS NOT NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION touch_admin_session(text) TO anon;


-- ============================================================
-- 6-3. 관리자 로그아웃 — 토큰 보유자만 자기 세션 해제
-- ============================================================
DROP FUNCTION IF EXISTS logout_admin_session(text);
CREATE FUNCTION logout_admin_session(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE admin_master
  SET admin_session_token = NULL, admin_session_expires_at = NULL
  WHERE admin_session_token = p_session_token;
  RETURN jsonb_build_object('success', FOUND);
END;
$$;

GRANT EXECUTE ON FUNCTION logout_admin_session(text) TO anon;


-- ============================================================
-- 6-4. 관리자 비밀번호 변경 — 토큰 + 기존 비밀번호 검증 후 갱신
--   보안: 기존비번 5회 오류 시 30분 잠금(무차별 대입 차단).
--         관리자는 단일세션 모델(동시접속 차단)이라 별도 세션 무효화 불필요.
-- ============================================================
CREATE OR REPLACE FUNCTION change_admin_password(
  p_session_token text,
  p_old_password  text,
  p_new_password  text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE v_admin admin_master%ROWTYPE;
BEGIN
  v_admin := _admin_session(p_session_token);
  IF v_admin.admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;

  -- 기존 비밀번호 검증 (오류 시 실패 카운트 증가 + 5회 도달 시 잠금)
  IF v_admin.admin_passwd_hash IS NULL
     OR v_admin.admin_passwd_hash <> crypt(p_old_password, v_admin.admin_passwd_hash) THEN
    UPDATE admin_master SET
      admin_login_fail_count = admin_login_fail_count + 1,
      admin_status = CASE
        WHEN admin_login_fail_count + 1 >= 5 THEN 'locked'
        ELSE admin_status
      END,
      admin_locked_until = CASE
        WHEN admin_login_fail_count + 1 >= 5 THEN now() + interval '30 minutes'
        ELSE admin_locked_until
      END
    WHERE admin_id = v_admin.admin_id;
    RETURN jsonb_build_object('success', false, 'error', 'WRONG_PASSWORD');
  END IF;

  IF length(p_new_password) < 4 THEN
    RETURN jsonb_build_object('success', false, 'error', 'TOO_SHORT');
  END IF;

  UPDATE admin_master SET
    admin_passwd_hash       = crypt(p_new_password, gen_salt('bf', 10)),
    admin_passwd_changed_at = now(),
    admin_login_fail_count  = 0
  WHERE admin_id = v_admin.admin_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION change_admin_password(text, text, text) TO anon;


-- ============================================================
-- 12. 주간공지 (weekly_notices)
-- ============================================================
-- Supabase Dashboard → Storage → New bucket 에서 아래 버킷 수동 생성:
--   이름: weekly-pdfs
--   Public: true (체크)
--   File size limit: 10485760 (10MB)
--   Allowed MIME types: application/pdf
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS weekly_notices (
  wn_id        SERIAL      PRIMARY KEY,
  wn_title     TEXT        NOT NULL,           -- 파일명 (확장자 포함)
  wn_date      TIMESTAMPTZ NOT NULL DEFAULT now(),
  wn_file_path TEXT        NOT NULL,           -- Storage 파일명 (weekly-pdfs 버킷 내 경로)
  wn_readcnt   INTEGER     NOT NULL DEFAULT 0,
  wn_hidden    BOOLEAN     NOT NULL DEFAULT false,
  wn_created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weekly_hidden ON weekly_notices (wn_hidden);
CREATE INDEX IF NOT EXISTS idx_weekly_id     ON weekly_notices (wn_id DESC);

-- 공개 목록 (홈 카드 4건, file_path 포함)
CREATE OR REPLACE FUNCTION get_weekly_list()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) FROM (
    SELECT wn_id, wn_title, wn_date, wn_file_path, wn_readcnt
    FROM weekly_notices
    WHERE wn_hidden = false
    ORDER BY wn_id DESC
    LIMIT 4
  ) n);
END;$$;
GRANT EXECUTE ON FUNCTION get_weekly_list() TO anon;

-- 공개 전체 목록 (전체보기 페이지네이션용)
CREATE OR REPLACE FUNCTION get_weekly_list_all()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) FROM (
    SELECT wn_id, wn_title, wn_date, wn_file_path, wn_readcnt
    FROM weekly_notices
    WHERE wn_hidden = false
    ORDER BY wn_id DESC
  ) n);
END;$$;
GRANT EXECUTE ON FUNCTION get_weekly_list_all() TO anon;

-- 관리자 전체 목록 (숨김 포함)
DROP FUNCTION IF EXISTS get_weekly_admin(text);
CREATE FUNCTION get_weekly_admin(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('error','UNAUTHORIZED'); END IF;
  RETURN (SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) FROM (
    SELECT wn_id, wn_title, wn_date, wn_file_path, wn_readcnt, wn_hidden
    FROM weekly_notices
    ORDER BY wn_id DESC
    LIMIT 500
  ) n);
END;$$;
GRANT EXECUTE ON FUNCTION get_weekly_admin(text) TO anon;

-- 조회수 증가 (anon 호출 가능)
CREATE OR REPLACE FUNCTION increment_weekly_readcnt(p_id integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE weekly_notices SET wn_readcnt = wn_readcnt + 1
  WHERE wn_id = p_id AND wn_hidden = false;
END;$$;
GRANT EXECUTE ON FUNCTION increment_weekly_readcnt(integer) TO anon;

-- 서명 업로드 URL 발급 (admin only)
-- 보안:
--   · service_role 키는 Supabase Vault에 암호화 저장 (평문 미보관)
--     → 사전 1회 실행: SELECT vault.create_secret('eyJ...키...', 'storage_service_key');
--   · 동기 HTTP는 http 확장(pgsql-http) 사용 (pg_net 은 비동기라 RPC 내 응답 대기 불가)
--   · SECURITY DEFINER + search_path 고정 + filename 검증으로 경로조작 차단
CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

DROP FUNCTION IF EXISTS get_weekly_upload_url(text, text);
CREATE FUNCTION get_weekly_upload_url(p_session_token text, p_filename text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, vault AS $$
DECLARE
  v         admin_master%ROWTYPE;
  v_key     text;
  v_base    text := 'https://rwplqifhmlduukipnksm.supabase.co';
  v_status  int;
  v_content text;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('error','UNAUTHORIZED'); END IF;

  -- 경로 조작 차단: 한글/영숫자/._- 만 허용 (슬래시·.. 거부)
  IF p_filename IS NULL OR p_filename !~ '^[\w가-힣._-]+$' THEN
    RETURN jsonb_build_object('error','BAD_FILENAME');
  END IF;

  -- 키는 Vault에서 복호화 (평문 미저장)
  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets WHERE name = 'storage_service_key';
  IF v_key IS NULL THEN RETURN jsonb_build_object('error','KEY_MISSING'); END IF;

  SELECT status, content INTO v_status, v_content
  FROM http(ROW(
    'POST',
    v_base || '/storage/v1/object/upload/sign/weekly-pdfs/' || p_filename,
    ARRAY[http_header('Authorization', 'Bearer ' || v_key)],
    'application/json',
    '{}'
  )::http_request);

  IF v_status BETWEEN 200 AND 299 THEN
    RETURN v_content::jsonb;
  ELSE
    RETURN jsonb_build_object('error','STORAGE_FAILED','status', v_status, 'detail', v_content);
  END IF;
END;$$;
GRANT EXECUTE ON FUNCTION get_weekly_upload_url(text, text) TO anon;

-- 조회용 서명 다운로드 URL 발급 (anon — 버킷 private 전제, 60초 만료)
-- 버킷 private 전환: UPDATE storage.buckets SET public = false WHERE id = 'weekly-pdfs';
DROP FUNCTION IF EXISTS get_weekly_download_url(integer);
CREATE FUNCTION get_weekly_download_url(p_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, vault AS $$
DECLARE
  v_key     text;
  v_base    text := 'https://rwplqifhmlduukipnksm.supabase.co';
  v_path    text;
  v_status  int;
  v_content text;
BEGIN
  SELECT wn_file_path INTO v_path FROM weekly_notices
  WHERE wn_id = p_id AND wn_hidden = false;
  IF v_path IS NULL THEN RETURN jsonb_build_object('error','NOT_FOUND'); END IF;

  SELECT decrypted_secret INTO v_key
  FROM vault.decrypted_secrets WHERE name = 'storage_service_key';
  IF v_key IS NULL THEN RETURN jsonb_build_object('error','KEY_MISSING'); END IF;

  SELECT status, content INTO v_status, v_content
  FROM http(ROW(
    'POST',
    v_base || '/storage/v1/object/sign/weekly-pdfs/' || v_path,
    ARRAY[http_header('Authorization', 'Bearer ' || v_key)],
    'application/json',
    '{"expiresIn":60}'
  )::http_request);

  IF v_status BETWEEN 200 AND 299 THEN
    RETURN v_content::jsonb;
  ELSE
    RETURN jsonb_build_object('error','STORAGE_FAILED','status', v_status, 'detail', v_content);
  END IF;
END;$$;
GRANT EXECUTE ON FUNCTION get_weekly_download_url(integer) TO anon;

-- 동일 파일명 교체용 — wn_title UNIQUE 제약
-- 기존 중복 wn_title 정리: 같은 제목 중 최신(wn_id 큰) 1건만 남기고 삭제
DELETE FROM weekly_notices a USING weekly_notices b
  WHERE a.wn_title = b.wn_title AND a.wn_id < b.wn_id;
ALTER TABLE weekly_notices DROP CONSTRAINT IF EXISTS weekly_notices_title_uniq;
ALTER TABLE weekly_notices ADD CONSTRAINT weekly_notices_title_uniq UNIQUE (wn_title);

-- Storage 파일 삭제 공통 헬퍼 (register_weekly 교체 / delete_weekly 공용)
--   삭제 실패는 무시(EXCEPTION) — 고아 파일만 잔존, 본 작업(등록/삭제)은 롤백 안 됨
CREATE OR REPLACE FUNCTION _delete_weekly_storage(p_path text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, vault AS $$
DECLARE
  v_key  text;
  v_base text := 'https://rwplqifhmlduukipnksm.supabase.co';
BEGIN
  IF p_path IS NULL OR trim(p_path) = '' THEN RETURN; END IF;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'storage_service_key';
  IF v_key IS NULL THEN RETURN; END IF;
  PERFORM http(ROW(
    'DELETE',
    v_base || '/storage/v1/object/weekly-pdfs/' || p_path,
    ARRAY[http_header('Authorization', 'Bearer ' || v_key)],
    NULL, NULL
  )::http_request);
EXCEPTION WHEN OTHERS THEN
  NULL;  -- Storage 삭제 실패 무시
END;$$;

-- 등록 (파일 업로드 완료 후 메타 저장)
--   인증: service_role(제어판 ps1) 직접 통과 / 그 외(관리자 웹)는 세션 토큰 검증
--   동일 wn_title → UPSERT(교체), 교체 시 이전 Storage 파일 삭제
DROP FUNCTION IF EXISTS register_weekly(text, text, text);
CREATE FUNCTION register_weekly(
  p_session_token text,
  p_title         text,
  p_file_path     text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, vault AS $$
DECLARE
  v_role text := current_setting('request.jwt.claims', true)::jsonb ->> 'role';
  v_id   integer;
  v_old  text;
BEGIN
  -- service_role 아니면 관리자 세션 검증
  IF v_role IS DISTINCT FROM 'service_role' THEN
    IF (_admin_session(p_session_token)).admin_id IS NULL THEN
      RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED');
    END IF;
  END IF;
  IF p_title IS NULL OR trim(p_title) = '' THEN RETURN jsonb_build_object('success',false,'error','TITLE_EMPTY'); END IF;
  IF p_file_path IS NULL OR trim(p_file_path) = '' THEN RETURN jsonb_build_object('success',false,'error','PATH_EMPTY'); END IF;

  -- 동일 파일명 기존 경로 보관 (교체 후 옛 파일 삭제용)
  SELECT wn_file_path INTO v_old FROM weekly_notices WHERE wn_title = p_title;

  INSERT INTO weekly_notices (wn_title, wn_file_path, wn_date)
  VALUES (p_title, p_file_path, now())
  ON CONFLICT (wn_title) DO UPDATE
    SET wn_file_path = EXCLUDED.wn_file_path, wn_date = now()
  RETURNING wn_id INTO v_id;

  -- 교체된 경우 이전 Storage 파일 삭제 (경로가 바뀐 경우만)
  IF v_old IS NOT NULL AND v_old <> p_file_path THEN
    PERFORM _delete_weekly_storage(v_old);
  END IF;

  RETURN jsonb_build_object('success', true, 'id', v_id);
END;$$;
GRANT EXECUTE ON FUNCTION register_weekly(text, text, text) TO anon, service_role;

-- 숨김 토글
DROP FUNCTION IF EXISTS toggle_weekly_hidden(text, integer, boolean);
CREATE FUNCTION toggle_weekly_hidden(p_session_token text, p_id integer, p_hidden boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED'); END IF;
  UPDATE weekly_notices SET wn_hidden = p_hidden WHERE wn_id = p_id;
  RETURN jsonb_build_object('success', FOUND);
END;$$;
GRANT EXECUTE ON FUNCTION toggle_weekly_hidden(text, integer, boolean) TO anon;

-- 삭제 (DB 행 + Storage 파일 동시 삭제)
DROP FUNCTION IF EXISTS delete_weekly(text, integer);
CREATE FUNCTION delete_weekly(p_session_token text, p_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, vault AS $$
DECLARE
  v      admin_master%ROWTYPE;
  v_path text;
BEGIN
  v := _admin_session(p_session_token);
  IF v.admin_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED'); END IF;

  SELECT wn_file_path INTO v_path FROM weekly_notices WHERE wn_id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','NOT_FOUND'); END IF;

  DELETE FROM weekly_notices WHERE wn_id = p_id;
  PERFORM _delete_weekly_storage(v_path);  -- Storage 파일도 삭제 (실패 무시)

  RETURN jsonb_build_object('success', true);
END;$$;
GRANT EXECUTE ON FUNCTION delete_weekly(text, integer) TO anon;
