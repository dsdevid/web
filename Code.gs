// =============================================
// 설정값 - 환경에 맞게 수정
// =============================================
const CONFIG = {
  SUPABASE_URL  : 'https://rwplqifhmlduukipnksm.supabase.co',
  SUPABASE_KEY  : 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3cGxxaWZobWxkdXVraXBua3NtIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTkwMDY3MywiZXhwIjoyMDk1NDc2NjczfQ.AsyefQGgZnp7er7IQujp9aZEUILPtCIIsuD08A7gp80',
  SHEET_NAME    : '공지사항',
  TABLE_NAME    : 'user_textnotice',
};

// 열 인덱스 (1-based)
const COL = {
  CHECK  : 1,  // A: 선택 (체크박스)
  ID     : 2,  // B: id (Supabase 반환 id 기록용)
  DATE   : 3,  // C: 일시
  OWNER  : 4,  // D: 작성자
  TITLE  : 5,  // E: 제목
  BODY   : 6,  // F: 내용
  READCNT: 7,  // G: 읽음
  HIDDEN : 8,  // H: 게시 (TRUE = 게시 = hidden FALSE)
};

// =============================================
// onEdit 트리거 - A열 체크 시 자동 실행
// =============================================
function onSheetEdit(e) {
  if (!e || !e.range) return;
  const { range, value, source } = e;

  const isCheckCol    = range.getColumn() === COL.CHECK;
  const isChecked     = value === 'TRUE';
  const sheet         = source.getActiveSheet();
  const isTargetSheet = sheet.getName() === CONFIG.SHEET_NAME;
  const isDataRow     = range.getRow() > 1;

  if (!isCheckCol || !isChecked || !isTargetSheet || !isDataRow) return;

  const row = range.getRow();
  sendRowToSupabase(sheet, row);
}

// =============================================
// 단일 행 Supabase 전송
// =============================================
function sendRowToSupabase(sheet, row) {
  const rowData = sheet.getRange(row, 1, 1, COL.HIDDEN).getValues()[0];

  const existingId  = rowData[COL.ID - 1];
  const dateVal     = rowData[COL.DATE - 1];
  const owner       = rowData[COL.OWNER - 1];
  const title       = rowData[COL.TITLE - 1];
  const body        = rowData[COL.BODY - 1];
  const readCnt     = rowData[COL.READCNT - 1] || 0;
  const isPublished = rowData[COL.HIDDEN - 1]; // TRUE = 게시중

  // 필수값 검증
  if (!owner || !title || !body) {
    showToast_(sheet, row, '❌ 작성자, 제목, 내용은 필수입니다');
    uncheckRow_(sheet, row);
    return;
  }

  // 날짜 포맷 (YYYY-MM-DD)
  const noticeDate = dateVal
    ? Utilities.formatDate(new Date(dateVal), Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss+09:00")
    : Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss+09:00");

  const payload = {
    textnotice_date  : noticeDate,
    textnotice_owner : String(owner),
    textnotice_title : String(title),
    textnotice_body  : String(body),
    // readcnt, hidden은 DB에서 관리 — 시트에서 덮어쓰지 않음
  };

  try {
    let responseData;

    if (existingId) {
      const existing = getFromSupabase_(`?textnotice_id=eq.${existingId}`);

      if (!existing || !existing[0]) {
        showToast_(sheet, row, '❌ DB에서 기존 데이터를 찾을 수 없습니다');
        uncheckRow_(sheet, row);
        setRowColor_(sheet, row, '#FFE0E0');
        return;
      }

      if (!hasChanged_(existing[0], payload)) {
        showToast_(sheet, row, '⚠️ 변경 내용이 없습니다');
        uncheckRow_(sheet, row);
        return;
      }

      responseData = supabaseRequest_('PATCH', `?textnotice_id=eq.${existingId}`, payload);
      showToast_(sheet, row, `✅ 업데이트 완료 (id: ${existingId})`);
    } else {
      // 신규 INSERT
      responseData = supabaseRequest_('POST', '', payload);
      // 반환된 id를 B열에 기록
      if (responseData && responseData[0]?.textnotice_id) {
        sheet.getRange(row, COL.ID).setValue(responseData[0].textnotice_id);
      }
      showToast_(sheet, row, '✅ 등록 완료');
    }

    uncheckRow_(sheet, row); // 전송 후 체크 해제
    setRowColor_(sheet, row, '#FFFFFF'); // 성공 시 배경 초기화

  } catch (err) {
    showToast_(sheet, row, `❌ 오류: ${err.message}`);
    uncheckRow_(sheet, row);
    setRowColor_(sheet, row, '#FFE0E0'); // 오류 시 배경 빨간색
  }
}

// =============================================
// Supabase REST API 요청 공통 함수
// =============================================
function supabaseRequest_(method, query, payload) {
  const url = `${CONFIG.SUPABASE_URL}/rest/v1/${CONFIG.TABLE_NAME}${query}`;

  const options = {
    method      : method,
    contentType : 'application/json',
    headers     : {
      'apikey'        : CONFIG.SUPABASE_KEY,
      'Authorization' : `Bearer ${CONFIG.SUPABASE_KEY}`,
      'Prefer'        : 'return=representation',
      'Content-Type'  : 'application/json',  // ← 명시적 추가
    },
    payload     : JSON.stringify(payload),
    muteHttpExceptions: true,
  };

  // 실제 요청/응답 로그 확인용 추가
  const response = UrlFetchApp.fetch(url, options);
  const statusCode = response.getResponseCode();
  const responseText = response.getContentText();

  // 로그로 상세 오류 확인
  console.log('STATUS:', statusCode);
  console.log('RESPONSE:', responseText);
  console.log('URL:', url);
  console.log('KEY 앞 20자:', CONFIG.SUPABASE_KEY.substring(0, 20));

  if (statusCode < 200 || statusCode >= 300) {
    throw new Error(`HTTP ${statusCode}: ${responseText}`);
  }

  return JSON.parse(responseText);
}

// =============================================
// 유틸 함수
// =============================================
function uncheckRow_(sheet, row) {
  sheet.getRange(row, COL.CHECK).setValue(false);
}

function showToast_(sheet, row, message) {
  SpreadsheetApp.getActiveSpreadsheet().toast(
    `${row}행 - ${message}`,
    '공지사항 전송',
    4
  );
}

function setRowColor_(sheet, row, color) {
  sheet.getRange(row, COL.CHECK, 1, COL.HIDDEN)
       .setBackground(color);
}

// DB에서 단일 행 조회
function getFromSupabase_(query) {
  const url = `${CONFIG.SUPABASE_URL}/rest/v1/${CONFIG.TABLE_NAME}${query}`;
  const response = UrlFetchApp.fetch(url, {
    method  : 'GET',
    headers : {
      'apikey'        : CONFIG.SUPABASE_KEY,
      'Authorization' : `Bearer ${CONFIG.SUPABASE_KEY}`,
    },
    muteHttpExceptions: true,
  });
  if (response.getResponseCode() !== 200) return null;
  return JSON.parse(response.getContentText());
}

// 시트 데이터와 DB 데이터 변경 여부 비교
function hasChanged_(dbRow, payload) {
  const dbDate      = dbRow.textnotice_date
    ? dbRow.textnotice_date.substring(0, 19)
    : '';
  const payloadDate = payload.textnotice_date
    ? payload.textnotice_date.substring(0, 19)
    : '';

  return (
    dbDate                 !== payloadDate              ||
    dbRow.textnotice_owner !== payload.textnotice_owner ||
    dbRow.textnotice_title !== payload.textnotice_title ||
    dbRow.textnotice_body  !== payload.textnotice_body
  );
}

// =============================================
// 웹 앱 진입점
// ※ 배포 설정: 실행 주체 = "나(스크립트 소유자)"
//              액세스 = "모든 사용자"
// URL: .../exec        → 메인 홈
// URL: .../exec?p=a    → 관리자 로그인/대시보드
// =============================================
function doGet(e) {
  const page = (e && e.parameter && e.parameter.p || '').toLowerCase();

  if (page === 'a') {
    return HtmlService.createHtmlOutputFromFile('admin')
      .setTitle('관리자 | 강남대성기숙 의대관')
      .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.DENY)
      .addMetaTag('viewport', 'width=device-width, initial-scale=1.0');
  }

  return HtmlService.createHtmlOutputFromFile('index')
    .setTitle('강남대성기숙 의대관')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1.0');
}

// =============================================
// 관리자 로그인 (ID + 비밀번호)
// - 비밀번호 검증: Supabase RPC process_admin_login (bcrypt 비교)
// - 성공 시 세션 토큰 발급 (CacheService, 30분)
// - 반환: { success, token, name, isSuperAdmin } 또는 { success:false, error, message }
// =============================================
function adminLogin(adminId, password) {
  if (!adminId || !password) {
    return { success: false, error: 'EMPTY_FIELD', message: '아이디와 비밀번호를 입력하세요' };
  }

  const result = supabaseRpc_('process_admin_login', {
    p_admin_id: adminId,
    p_password: password
  });

  if (!result || !result.success) {
    const msgMap = {
      NOT_FOUND:      '계정을 찾을 수 없습니다',
      WRONG_PASSWORD: '비밀번호가 올바르지 않습니다',
      LOCKED:         '계정이 잠겼습니다. 잠시 후 다시 시도하세요',
      INACTIVE:       '비활성화된 계정입니다',
      NO_PASSWORD:    '비밀번호가 설정되지 않은 계정입니다'
    };
    const code = result ? result.error : 'NETWORK_ERROR';
    return { success: false, error: code, message: msgMap[code] || '로그인 실패' };
  }

  // 세션 토큰 발급 (30분)
  const token = Utilities.getUuid();
  CacheService.getScriptCache().put(
    'adm_' + token,
    JSON.stringify({
      adminId:      result.admin_id,
      name:         result.admin_name,
      isSuperAdmin: result.admin_is_super_admin
    }),
    1800
  );

  return {
    success:      true,
    token:        token,
    name:         result.admin_name,
    isSuperAdmin: result.admin_is_super_admin
  };
}

// =============================================
// 관리자 로그아웃 (세션 토큰 삭제)
// =============================================
function adminLogout(token) {
  if (token) CacheService.getScriptCache().remove('adm_' + token);
  return true;
}

// 세션 토큰 검증 (내부용)
function verifySession_(token) {
  if (!token) return null;
  const cached = CacheService.getScriptCache().get('adm_' + token);
  if (!cached) return null;
  return JSON.parse(cached);
}

// =============================================
// 관리자 대시보드 데이터 조회
// =============================================
function getAdminDashboardData(token) {
  const auth = verifySession_(token);
  if (!auth) throw new Error('UNAUTHORIZED');

  const tz = Session.getScriptTimeZone();
  const todayStart = Utilities.formatDate(
    new Date(), tz, "yyyy-MM-dd'T'00:00:00+09:00"
  );

  const recentNotices = supabaseQuery_(
    'user_textnotice',
    '?order=textnotice_date.desc&limit=5' +
    '&select=textnotice_id,textnotice_title,textnotice_date,textnotice_readcnt,textnotice_hidden'
  ) || [];

  const todayNotices = supabaseQuery_(
    'user_textnotice',
    '?textnotice_date=gte.' + todayStart + '&select=textnotice_id'
  ) || [];

  const result = {
    admin:         auth,
    todayCount:    todayNotices.length,
    recentNotices: recentNotices
  };

  if (auth.isSuperAdmin) {
    result.adminLogins = supabaseQuery_(
      'admin_master',
      '?order=admin_last_login_at.desc&limit=5' +
      '&select=admin_name,admin_email,admin_last_login_at,admin_is_super_admin'
    ) || [];
  }

  return result;
}

// =============================================
// Supabase 범용 쿼리 / 업데이트 (table 지정 가능)
// =============================================
function supabaseQuery_(table, query) {
  const url = CONFIG.SUPABASE_URL + '/rest/v1/' + table + query;
  const res = UrlFetchApp.fetch(url, {
    method: 'GET',
    headers: {
      'apikey':        CONFIG.SUPABASE_KEY,
      'Authorization': 'Bearer ' + CONFIG.SUPABASE_KEY
    },
    muteHttpExceptions: true
  });
  if (res.getResponseCode() !== 200) return null;
  return JSON.parse(res.getContentText());
}

function supabaseUpdate_(table, query, payload) {
  const url = CONFIG.SUPABASE_URL + '/rest/v1/' + table + query;
  UrlFetchApp.fetch(url, {
    method:      'PATCH',
    contentType: 'application/json',
    headers: {
      'apikey':        CONFIG.SUPABASE_KEY,
      'Authorization': 'Bearer ' + CONFIG.SUPABASE_KEY,
      'Prefer':        'return=minimal'
    },
    payload:            JSON.stringify(payload),
    muteHttpExceptions: true
  });
}

// =============================================
// 학생 로그인 (학번 + 이름 → user_master 확인)
// user_master 테이블 생성 후 활성화됨
// =============================================
function studentLogin(studentId, studentName) {
  if (!studentId || !studentName) {
    return { success: false, error: 'EMPTY_FIELD', message: '학번과 이름을 입력하세요' };
  }

  var result = supabaseRpc_('process_student_login', {
    p_student_id:   studentId.trim(),
    p_student_name: studentName.trim()
  });

  if (!result || !result.success) {
    var msgMap = {
      NOT_FOUND: '학번 또는 이름이 올바르지 않습니다',
      INACTIVE:  '등록되지 않은 계정입니다'
    };
    var code = result ? result.error : 'NETWORK_ERROR';
    return { success: false, error: code, message: msgMap[code] || '로그인 실패' };
  }

  var token = Utilities.getUuid();
  CacheService.getScriptCache().put(
    'std_' + token,
    JSON.stringify({
      studentId: result.student_id,
      name:      result.student_name,
      ban:       result.student_ban,
      prt:       result.student_prt
    }),
    1800
  );

  return {
    success: true,
    token:   token,
    name:    result.student_name,
    ban:     result.student_ban,
    prt:     result.student_prt
  };
}

function studentLogout(token) {
  if (token) CacheService.getScriptCache().remove('std_' + token);
  return true;
}

// Supabase RPC 호출 (저장 프로시저)
function supabaseRpc_(funcName, params) {
  const url = CONFIG.SUPABASE_URL + '/rest/v1/rpc/' + funcName;
  const res = UrlFetchApp.fetch(url, {
    method:      'POST',
    contentType: 'application/json',
    headers: {
      'apikey':        CONFIG.SUPABASE_KEY,
      'Authorization': 'Bearer ' + CONFIG.SUPABASE_KEY
    },
    payload:            JSON.stringify(params),
    muteHttpExceptions: true
  });
  if (res.getResponseCode() !== 200) return null;
  return JSON.parse(res.getContentText());
}

// =================================================================================
// 등록을 위해 최초 1회 실행
// =================================================================================
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => {
    ScriptApp.deleteTrigger(t);
  });

  // onSheetEdit 으로 변경
  ScriptApp.newTrigger('onSheetEdit')
    .forSpreadsheet(SpreadsheetApp.getActiveSpreadsheet())
    .onEdit()
    .create();

  console.log('트리거 등록 완료:', ScriptApp.getProjectTriggers().length);
}





