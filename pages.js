// ============================================================
// 페이지 레지스트리 — 계층(레벨) + 권한 캐스케이드
//   새 페이지는 PAGES 에 한 줄 추가하면 등록 + 권한 지정 완료.
//   parent : 상위 페이지 id (null = 레벨1 최상위)
//   access : 'public'(누구나) | 'user'(로그인 학생 이상) | 'admin'(관리자만)
//
//   ★ 캐스케이드: 어떤 페이지 접근 = 자신 + 모든 상위 노드를 전부 통과해야 함.
//      상위(레벨1)가 차단되면 그 하위(레벨2,3…) 전부 차단.
//   ★ 권한 레벨: public(0) < user(1) < admin(2). 역할 레벨 >= 노드 요구 레벨이면 통과.
//      guest=0, user=1, admin=2.
//
//   사용:
//     - 레벨1 섹션 노출/숨김(메인):  applyAccess()   (로드 + 로그인/로그아웃 시 호출)
//     - 하위 페이지 메뉴 렌더:        renderPageNav('navPages')
//     - 보호 페이지 가드(파일 최상단): requirePage('penalty_list')
//
//   ※ 정적 사이트 한계: 클라이언트 가드는 메뉴/진입 차단(UX)용.
//      민감 데이터는 반드시 Supabase RPC(서버)에서도 막아야 함.
// ============================================================

var PAGES = [
  // ── 레벨1 (parent: null) — 메인 섹션 ──
  { id: 'notice',  name: '공지사항',     url: '#notice',  access: 'public', parent: null },
  { id: 'weekly',  name: '주간공지',     url: '#weekly',  access: 'public', parent: null },
  { id: 'stats',   name: '통계현황',     url: '#stats',   access: 'user',   parent: null },
  { id: 'search',  name: '검색',         url: '#search',  access: 'public', parent: null },
  { id: 'rules',   name: '학원규정',     url: '#rules',   access: 'public', parent: null },
  { id: 'penalty', name: '반별벌점현황', url: '#penalty', access: 'user',   parent: null },

  // ── 레벨2,3… 하위 페이지 — parent 지정해 추가 (예시) ──
  // { id: 'penalty_list', name: '벌점내역', url: 'penalty.html', access: 'admin', parent: 'penalty' },
];

// 현재 접속 역할: 'admin' | 'user' | 'guest'
function currentRole() {
  if (localStorage.getItem('adm_id'))        return 'admin';
  if (sessionStorage.getItem('std_session')) return 'user';
  return 'guest';
}

// 권한 레벨: public(0) < user(1) < admin(2)
var ACCESS_LEVEL = { public: 0, user: 1, admin: 2 };
function roleLevel(role) {
  return role === 'admin' ? 2 : role === 'user' ? 1 : 0;   // guest = 0
}

// 자신부터 루트까지 거슬러 올라가며 전부 통과해야 true (캐스케이드)
//   역할 레벨 >= 노드 요구 레벨이어야 통과. 상위 노드 하나라도 부족하면 차단.
function canAccess(id, role) {
  role = role || currentRole();
  var rl = roleLevel(role);
  var p = PAGES.find(function (x) { return x.id === id; });
  while (p) {
    if (rl < ACCESS_LEVEL[p.access]) return false;
    p = p.parent ? PAGES.find(function (x) { return x.id === p.parent; }) : null;
  }
  return true;
}

// 현재 역할이 접근 가능한 페이지 목록
function allowedPages(role) {
  role = role || currentRole();
  return PAGES.filter(function (p) { return canAccess(p.id, role); });
}

// 하위 페이지 네비 렌더 — 지정 컨테이너에 링크 생성
function renderPageNav(containerId) {
  var el = document.getElementById(containerId);
  if (!el) return;
  el.innerHTML = allowedPages().map(function (p) {
    return '<a href="' + p.url + '">' + p.name + '</a>';
  }).join('');
}

// 레벨1 섹션 노출/숨김 — 차단 항목은 섹션 + 네비링크 + 아코디언 패널 모두 숨김
function applyAccess() {
  var role = currentRole();
  PAGES.filter(function (p) { return p.parent === null; }).forEach(function (p) {
    var ok  = canAccess(p.id, role);
    var disp = ok ? '' : 'none';

    // 1) 섹션 본체 (#id)
    var anchor = (p.url && p.url.charAt(0) === '#') ? p.url.slice(1) : null;
    if (anchor) {
      var sec = document.getElementById(anchor);
      if (sec) sec.style.display = disp;
    }

    // 2) 같은 앵커를 가리키는 링크들 — 아코디언 패널은 통째로, 그 외는 링크만
    document.querySelectorAll('a[href="' + p.url + '"]').forEach(function (a) {
      var panel = a.closest ? a.closest('.va-panel') : null;
      if (panel) panel.style.display = disp;
      else       a.style.display     = disp;
    });
  });

  // 마지막 보이는 아코디언 패널에 va-last (타이틀 우측 세로선 숨김 -28px)
  var last = null;
  document.querySelectorAll('.va-panel').forEach(function (pan) {
    pan.classList.remove('va-last');
    if (pan.style.display !== 'none') last = pan;
  });
  if (last) last.classList.add('va-last');
}

// 보호 페이지 가드 — 보호 페이지 최상단에서 호출. 미허가면 홈으로.
function requirePage(pageId) {
  var page = PAGES.find(function (p) { return p.id === pageId; });
  if (!page) return;                                 // 미등록 페이지는 통과
  if (!canAccess(page.id)) {
    alert('접근 권한이 없습니다. 로그인 후 이용하세요.');
    location.href = 'index.html';
  }
}
