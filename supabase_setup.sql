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

-- 인덱스 (로그인 시 email로 조회)
CREATE INDEX IF NOT EXISTS idx_admin_email  ON admin_master (admin_email);
CREATE INDEX IF NOT EXISTS idx_admin_status ON admin_master (admin_status);


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
-- 7. 학생 로그인 RPC (user_master 테이블 생성 후 실행)
--    학번 + 이름으로 본인 확인
-- ============================================================
CREATE OR REPLACE FUNCTION process_student_login(p_student_id text, p_student_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_student user_master%ROWTYPE;
BEGIN
  SELECT * INTO v_student
  FROM user_master
  WHERE mst_id = p_student_id AND mst_name = p_student_name;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
  END IF;

  RETURN jsonb_build_object(
    'success',      true,
    'student_id',   v_student.mst_id,
    'student_name', v_student.mst_name,
    'student_ban',  v_student.mst_ban,
    'student_prt',  v_student.mst_prt
  );
END;
$$;


-- ============================================================
-- 10. 공지사항 DB 연동 (Supabase SQL Editor에서 실행)
-- ============================================================

-- 고정 컬럼 추가 (이미 있으면 무시)
ALTER TABLE user_textnotice
  ADD COLUMN IF NOT EXISTS textnotice_pin boolean NOT NULL DEFAULT false;

-- 공개 공지 조회 (anon — 비공개 제외, 고정 우선)
CREATE OR REPLACE FUNCTION get_notices_public()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(n), '[]'::jsonb) FROM (
    SELECT textnotice_id, textnotice_date, textnotice_owner,
           textnotice_title, textnotice_body, textnotice_readcnt, textnotice_pin
    FROM user_textnotice
    WHERE textnotice_hidden = false
    ORDER BY textnotice_pin DESC, textnotice_date DESC
  ) n);
END;$$;
GRANT EXECUTE ON FUNCTION get_notices_public() TO anon;

-- 관리자 공지 조회 (전체, 숨김 포함)
CREATE OR REPLACE FUNCTION get_notices_admin(p_admin_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  SELECT * INTO v FROM admin_master WHERE admin_id = p_admin_id AND admin_status = 'active';
  IF NOT FOUND THEN RETURN jsonb_build_object('error','UNAUTHORIZED'); END IF;
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
CREATE OR REPLACE FUNCTION save_notice(
  p_admin_id text, p_id integer,
  p_title text, p_body text, p_owner text,
  p_hidden boolean, p_pin boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE; v_id integer;
BEGIN
  SELECT * INTO v FROM admin_master WHERE admin_id = p_admin_id AND admin_status = 'active';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED'); END IF;
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
CREATE OR REPLACE FUNCTION delete_notice(p_admin_id text, p_id integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v admin_master%ROWTYPE;
BEGIN
  SELECT * INTO v FROM admin_master WHERE admin_id = p_admin_id AND admin_status = 'active';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','UNAUTHORIZED'); END IF;
  DELETE FROM user_textnotice WHERE textnotice_id = p_id;
  RETURN jsonb_build_object('success',true);
END;$$;
GRANT EXECUTE ON FUNCTION delete_notice(text,integer) TO anon;


-- ============================================================
-- 8. anon 권한 부여 (브라우저에서 직접 호출용)
--    Supabase Dashboard → Settings → API → anon public key 사용
-- ============================================================
GRANT EXECUTE ON FUNCTION process_admin_login(text, text)  TO anon;
GRANT EXECUTE ON FUNCTION process_student_login(text, text) TO anon;

-- user_textnotice: 게시된 공지만 anon 조회 허용
ALTER TABLE user_textnotice ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon_read_published" ON user_textnotice;
CREATE POLICY "anon_read_published" ON user_textnotice
  FOR SELECT TO anon USING (textnotice_hidden = false);


-- ============================================================
-- 9. 관리자 대시보드 데이터 RPC
--    admin_id 확인 후 대시보드 데이터 반환 (SECURITY DEFINER = RLS 우회)
-- ============================================================
CREATE OR REPLACE FUNCTION get_admin_dashboard_data(p_admin_id text)
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
  SELECT * INTO v_admin FROM admin_master
  WHERE admin_id = p_admin_id AND admin_status = 'active';
  IF NOT FOUND THEN
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
BEGIN
  -- 계정 조회
  SELECT * INTO v_admin FROM admin_master WHERE admin_id = p_admin_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND');
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
    RETURN jsonb_build_object('success', false, 'error', 'INACTIVE');
  END IF;

  -- 비밀번호 미설정 확인
  IF v_admin.admin_passwd_hash IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_PASSWORD');
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

    RETURN jsonb_build_object('success', false, 'error', 'WRONG_PASSWORD');
  END IF;

  -- 로그인 성공: 실패 카운트 초기화 + 마지막 로그인 갱신
  UPDATE admin_master
  SET
    admin_login_fail_count   = 0,
    admin_last_login_at      = now(),
    admin_session_expires_at = now() + interval '30 minutes'
  WHERE admin_id = p_admin_id;

  RETURN jsonb_build_object(
    'success',              true,
    'admin_id',             v_admin.admin_id,
    'admin_name',           v_admin.admin_name,
    'admin_is_super_admin', v_admin.admin_is_super_admin
  );
END;
$$;
