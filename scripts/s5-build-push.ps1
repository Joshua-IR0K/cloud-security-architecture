# 절차: buildx build → Trivy 게이트 → ECR 로그인 → push → 검증
#
# 사용:
#   .\scripts\s5-build-push.ps1 -Variant good
#   .\scripts\s5-build-push.ps1 -Variant vuln -SkipTrivyGate
#   .\scripts\s5-build-push.ps1 -Variant good -Tag s5-immutability-test   # ③ 축 실험

param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("good", "vuln")]
  [string]$Variant,

  # 태그를 직접 지정 (③ IMMUTABLE 실험에서 같은 태그 재사용에 사용)
  [string]$Tag = "",

  # 취약 이미지는 게이트를 통과할 수 없으므로 의도적으로 우회
  [switch]$SkipTrivyGate,

  [string]$Region  = "ap-northeast-2",
  [string]$Profile = "devsecops-admin"
)

$ErrorActionPreference = "Stop"
$env:AWS_PROFILE = $Profile

function Step($msg) { Write-Host "`n[s5] $msg" -ForegroundColor Cyan }

# 0. 사전 확인
Step "사전 확인"
#   ⚠ 네이티브 CLI 호출은 exit code 로 판정한다
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$acct = & aws sts get-caller-identity --query "Account" --output text 2>$null
$stsExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
if ($stsExit -ne 0 -or [string]::IsNullOrWhiteSpace($acct)) {
  throw "[s5] AWS 자격증명 없음 — 'aws sso login --profile $Profile' 후 재시도"
}
Write-Host "     account = $acct"

# 리포지토리 URL 은 02-security 가 SSM 으로 발행 (크로스스택 계약)
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$repoUrl = & aws ssm get-parameter --name "/devsecops-project/security/ecr_repository_url" `
             --query "Parameter.Value" --output text 2>$null
$ssmExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
if ($ssmExit -ne 0 -or [string]::IsNullOrWhiteSpace($repoUrl)) {
  throw "[s5] ECR 리포지토리 URL 조회 실패 — 02-security 를 먼저 apply 했는지 확인"
}
Write-Host "     repo    = $repoUrl"

# 1. 태그 결정
# latest 를 쓰지 않는다: 어떤 커밋의 산출물인지 식별할 수 없고,
# IMMUTABLE 리포지토리에서 재사용이 불가능하며, S6/S7 의 태그 진화와 어긋난다.
#   S5: s5-<variant>-<git sha>   S6: s6-<full GITHUB_SHA>   S7: digest + 서명
if ([string]::IsNullOrWhiteSpace($Tag)) {
  $sha = (& git rev-parse --short HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) { $sha = "nogit" }
  $Tag = "s5-$Variant-$sha"
}
$image   = "${repoUrl}:${Tag}"
$context = "images/s5-$Variant"
Step "빌드 대상: $image  (context: $context)"

# 2. buildx 빌드
# buildx(BuildKit)를 쓰는 이유: S6 에서 SBOM·provenance attestation 을
# 붙일 때 같은 빌더를 그대로 쓴다 — 골든 패스와 CI 의 도구를 일치시킨다.
# --platform linux/amd64: 노드가 x86_64 (AL2023_x86_64_STANDARD)
# ⚠ --provenance=false --sbom=false:
#   buildx 기본값은 provenance attestation 을 생성하는데, 그러면 푸시 결과가
#     태그 → Image Index → [ Image, attestation ]
#   구조가 된다. Inspector 는 **인덱스를 스캔하지 못하고**(UNSUPPORTED_MEDIA_TYPE)
#   실제 이미지는 태그가 없어서(SUCCESSFUL, tag=null) 콘솔·CLI 모두에서
#   "태그별 취약점"이 보이지 않는다. 스캔은 됐는데 연결이 끊기는 것.
#   → S5 의 목적(태그별 스캔 결과 대비)을 위해 단일 매니페스트로 푸시한다.
#   → S6 는 Syft로 digest 기준 SBOM을 별도 생성·보존하고, OCI attestation/서명은 S7로 미룬다.
Step "docker buildx build"
# --build-arg: 페이지에 빌드 identity 를 굽는다 — 로컬 빌드는 git sha 사용
$buildSha = (& git rev-parse HEAD 2>$null); if ($LASTEXITCODE -ne 0) { $buildSha = "local" }
& docker buildx build --platform linux/amd64 --provenance=false --sbom=false `
    --build-arg "BUILD_SHA=$buildSha" `
    --load -t $image $context
if ($LASTEXITCODE -ne 0) { throw "[s5] 빌드 실패" }

# 3. Trivy 게이트 (빌드타임, shift-left)
# Inspector 와 역할이 다르다 — 중복이 아니라 "시점"이 다른 이중화:
#   Trivy     = 푸시 "전" 차단 (레지스트리에 취약 이미지가 들어가지 않게)
#   Inspector = 푸시 "후" 지속 재평가 (신규 CVE 공시 대응)
if ($SkipTrivyGate) {
  Write-Warning "[s5] Trivy 게이트 우회 — 취약 이미지를 의도적으로 푸시 (검증 축 ①)"
  & trivy image --severity HIGH,CRITICAL --scanners vuln $image
  # ↑ 게이트는 아니지만 로컬 스캔 결과를 증거로 남긴다 (exit code 무시)
} else {
  Step "Trivy 게이트 (HIGH/CRITICAL 발견 시 푸시 차단)"
  & trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln $image
  if ($LASTEXITCODE -ne 0) {
    throw "[s5] Trivy 게이트 차단 — HIGH/CRITICAL 취약점. 푸시하지 않음."
  }
}

# 4. ECR 로그인
# 장기 액세스 키를 쓰지 않는다 — SSO 단기 세션으로 얻은 자격으로 토큰 발급.
# (S6 에서는 이 부분이 GitHub OIDC 로 대체된다 — 역시 장기 키 없음)
Step "ECR 로그인"
$registry = $repoUrl.Split("/")[0]
& aws ecr get-login-password --region $Region | & docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "[s5] ECR 로그인 실패" }

# 5. 푸시
Step "docker push"
& docker push $image
$pushExit = $LASTEXITCODE
if ($pushExit -ne 0) {
  Write-Warning "[s5] 푸시 실패 (exit $pushExit)"
  Write-Warning "     같은 태그를 재사용했다면 ImageTagAlreadyExistsException 이 정상이다"
  Write-Warning "     → 검증 축 ③ IMMUTABLE 의 증거. 위 에러 메시지를 캡처할 것."
  exit $pushExit
}

# 6. 결과
Step "푸시 완료 — digest 확인"
# registry host 뒤의 전체 path가 ECR repository name이다.
# 예: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/devsecops-project/app
#     -> devsecops-project/app (마지막 "app" 만 쓰면 조회 실패)
$repoName = $repoUrl.Substring($repoUrl.IndexOf("/") + 1)
& aws ecr describe-images --repository-name $repoName `
    --image-ids imageTag=$Tag `
    --query "imageDetails[].{tag:imageTags[0],digest:imageDigest,pushed:imagePushedAt,size:imageSizeInBytes}"

Write-Host "`n[s5] 이미지: $image" -ForegroundColor Green
Write-Host "[s5] Inspector 지속 스캔이 자동 적용된다 (레지스트리 레벨 ENHANCED/CONTINUOUS)."
Write-Host "[s5] findings 확인은 STAGE5_RUNBOOK.md 의 검증 축 ① 명령 참고 (반영까지 수 분 소요)."
