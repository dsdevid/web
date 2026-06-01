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
