# ============================================================
# scripts/session-ritual.ps1 — 세션 시작 리추얼 (매 세션 1회)
# ============================================================
# 역할 3개:
#   1) AWS_PROFILE 설정
#   2) 현재 공인 IPv4 조회 → TF_VAR_my_ip 주입 (디스크·VCS 무접촉)
#   3) 기존 클러스터 allowlist 와의 "드리프트 감지" — 관리 평면(AWS API)은
#      IP 와 무관하게 항상 도달 가능하므로 여기서 안전하게 비교 가능
#
# 설계 원칙: 스크립트는 관찰만, 인프라 변경은 명시적 terraform 명령으로.
#   (드리프트 발견 시 자동 복구하지 않고 복구 명령을 "안내"만 한다 —
#    세션 스크립트가 2~5분짜리 클러스터 업데이트를 몰래 수행하지 않도록)
# ============================================================

param(
  [string]$ClusterName = "joshua-eks",
  [string]$AwsProfile  = "devsecops-admin"
)

$ErrorActionPreference = "Stop"
$env:AWS_PROFILE = $AwsProfile
Write-Host "[ritual] AWS_PROFILE = $AwsProfile"

# ── 1) 현재 공인 IPv4 조회 ─────────────────────────────────
# curl.exe -4 : 듀얼스택 회선에서 IPv6 로 붙어 IPv6 주소가 반환되는 것을
#               원천 차단 (외부 리뷰 제안 채택 — Invoke-RestMethod 대비 개선)
# -f          : HTTP 에러 시 본문 대신 실패 종료 (에러 페이지 캡처 방지)
# --max-time 5: 무한 대기 방지
$ip = & curl.exe -4fsS --max-time 5 https://checkip.amazonaws.com
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip)) {
  throw "[ritual] 공인 IPv4 감지 실패 — 네트워크 또는 checkip 엔드포인트 확인. (오프라인 작업 시 수동 주입: `$env:TF_VAR_my_ip = '<IP>')"
}
$ip = $ip.Trim()

# fail-closed 1차 가드 (2차 백스톱 = variables.tf 의 validation 블록)
$ipv4 = '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$'
if ($ip -notmatch $ipv4) {
  throw "[ritual] IPv4 형식 아님: '$ip' — 캡티브 포털/프록시 변조 의심. allowlist 오염 방지 위해 중단."
}

$env:TF_VAR_my_ip = $ip
Write-Host "[ritual] TF_VAR_my_ip = $ip  (Terraform '입력 평면' 갱신 완료)"

# ── 2) allowlist 드리프트 감지 (관리 평면 — 잠김과 무관하게 동작) ──
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"

$cidrs = & aws eks describe-cluster `
  --name $ClusterName `
  --region ap-northeast-2 `
  --query "cluster.resourcesVpcConfig.publicAccessCidrs" `
  --output text 2>$null

$awsExitCode = $LASTEXITCODE

$ErrorActionPreference = $previousErrorActionPreference

if ($awsExitCode -ne 0) {
  Write-Host "[ritual] 클러스터 '$ClusterName' 없음 (destroy 상태) — 드리프트 해당 없음, 첫 apply 경로"
}
elseif ($cidrs -match [regex]::Escape("$ip/32")) {
  Write-Host "[ritual] allowlist 일치 ($ip/32) — K8s API 접근 정상, 바로 plan/apply 가능"
}
else {
  Write-Warning "IP 드리프트 감지: 클러스터 allowlist=[$cidrs] / 현재=$ip/32"
  Write-Warning "이대로 plan/apply/destroy 하면 K8s 프로바이더 refresh 가 기존 endpoint 에서 타임아웃."
  Write-Warning "잠금 해제 (관리 평면 전용 — K8s 프로바이더가 그래프에서 제외됨):"
  Write-Warning "    cd 04-eks ; terraform apply -target=module.eks"
  Write-Warning "완료 후 평소처럼 진행 (destroy 도 동일: 잠금 해제 -> destroy)"
}
