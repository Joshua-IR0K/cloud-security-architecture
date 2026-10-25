# ============================================================
# 05-k8s/outputs.tf — 검증 헬퍼 (kubectl 명령 생성)
# ============================================================
# 실행: Invoke-Expression (terraform output -raw <이름>)
#
# 04 소유 AWS 리소스 이름은 "결정론적 재구성"으로 얻는다 —
# SSM 계약을 늘리지 않기 위함(결정 a: 계약은 cluster_name 하나).
#   버킷명 = <project>-s2-identity-demo-<account_id>  (04 와 동일 공식)
# ============================================================

data "aws_caller_identity" "current" {}

locals {
  s2_bucket = "${var.project_name}-s2-identity-demo-${data.aws_caller_identity.current.account_id}"
}

output "s2_verify_denied" {
  description = "① BREAK — '자격증명 부재'로 실패해야 정상 (성공하면 IMDS 경로 의심)"
  value       = "kubectl exec deploy/identity-denied -- aws s3 ls s3://${local.s2_bucket} --region ${var.region}"
}

output "s2_verify_granted" {
  description = "② 성공해야 정상 — hello-from-stage2.txt 가 보임"
  value       = "kubectl exec deploy/identity-granted -- aws s3 ls s3://${local.s2_bucket} --region ${var.region}"
}

output "s2_verify_scope" {
  description = "③ 스코프 증명 — 전체 버킷 목록은 AccessDenied 여야 정상 (ListAllMyBuckets 의도적 부재)"
  value       = "kubectl exec deploy/identity-granted -- aws s3 ls --region ${var.region}"
}

output "s2_cni_restart" {
  description = "Phase A — aws-node 재기동 (Pod Identity 주입 반영, 소급 미적용 해소)"
  value       = "kubectl -n kube-system rollout restart daemonset aws-node ; kubectl -n kube-system rollout status daemonset aws-node"
}

output "s2_cni_env_check" {
  description = <<-EOT
    Phase A 게이트 1 — Pod Identity 주입 확인 (env 2개 + 토큰 볼륨).
    ⚠ 컨테이너 exec 방식(printenv) 금지: 최신 VPC CNI 이미지는 최소 베이스라
      셸 유틸리티가 없어 "executable file not found" 로 실패 (트러블슈팅 #8).
      상태 확인은 컨테이너 내부가 아니라 API 서버에서 한다.
    ⚠ DaemonSet 이 아니라 "파드"를 조회할 것 — 주입은 admission-time 에
      파드에만 일어나므로 DaemonSet 템플릿에는 나타나지 않음.
  EOT
  value       = "kubectl -n kube-system describe pod -l k8s-app=aws-node | Select-String \"AWS_CONTAINER_CREDENTIALS_FULL_URI|AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE|eks-pod-identity-token\""
}

output "s2_cni_addon_check" {
  description = "Phase A 보조 — 애드온 레벨에서 Pod Identity 연결이 실제로 걸렸는지"
  value       = "aws eks describe-addon --cluster-name ${local.cluster_name} --addon-name vpc-cni --region ${var.region} --query \"addon.podIdentityAssociations\""
}

output "s3_netpol_status" {
  description = "정책 목록 — 게이트 ON 이면 default 3개(deny/dns/identity) + app 2개(deny/alb), OFF 면 0개"
  value       = "kubectl get networkpolicy -A"
}

output "s3_verify_pod_to_pod" {
  description = <<-EOT
    핵심 실증 — 클라이언트 → nginx (east-west).
    BEFORE(게이트 OFF): HTML 응답  /  AFTER(ON): 타임아웃 = 차단
    ※ DNS 는 허용 정책이 있으므로 이름 해석은 계속 성공 —
      실패 원인이 DNS 가 아니라 L3/L4 정책임이 분리 증명됨
  EOT
  value       = "kubectl exec deploy/netpol-client -- wget -qO- --timeout=5 http://nginx.app"
}

output "s3_verify_placement" {
  description = "배치 확인 — 노드 2대에서 nginx 가 흩어지면(파트 3) client 는 nginx 1개와 같은 노드: 동일·교차 노드 모두 차단돼야 정상"
  value       = "kubectl get pods -A -o wide -l 'app in (nginx,netpol-client)'"
}

output "s3_verify_imds_blocked" {
  description = <<-EOT
    IMDS 차단 확인 (겹방어 2층) — 타임아웃이 정답.
    1층 hop-limit=1(S1) + 2층 NetworkPolicy except 169.254.169.254/32(S3)
  EOT
  value       = "kubectl exec deploy/netpol-client -- wget -qO- --timeout=3 http://169.254.169.254/latest/meta-data/"
}

output "s3_verify_aws_api_allowed" {
  description = "IMDS 는 막고 AWS API 는 통과 — 게이트 ON 상태에서도 S2 의 ② 가 계속 성공해야 정상"
  value       = "kubectl exec deploy/identity-granted -- aws s3 ls s3://${local.s2_bucket} --region ${var.region}"
}

output "s3_node_scale" {
  description = "노드 1→2 스케일 (⚠ 모듈이 desired_size 를 무시하므로 Terraform 이 아닌 CLI — D6)"
  value       = "aws eks update-nodegroup-config --cluster-name ${local.cluster_name} --region ${var.region} --nodegroup-name $(aws eks list-nodegroups --cluster-name ${local.cluster_name} --region ${var.region} --query \"nodegroups[0]\" --output text) --scaling-config minSize=0,maxSize=3,desiredSize=2"
}


# ============================================================
# Stage 4 검증 — 3축 + D9 증명
# ============================================================

# ── ① BREAK: 자격 없는 파드는 기동 자체가 안 됨 ───────────
output "s4_verify_denied" {
  description = "①실패가 정답 — ContainerCreating 에서 멈춤 (마운트 실패)"
  value       = "kubectl get pods -l role=s4-denied ; kubectl describe pod -l role=s4-denied | Select-String 'FailedMount|not authorized|Warning'"
}

# ── ② BUILD: 마운트된 파일 확인 ───────────────────────────
output "s4_verify_mounted" {
  description = "②성공이 정답 — db-username, db-password 파일이 보임"
  value       = "kubectl exec deploy/secrets-granted -- ls -l /mnt/secrets-store/"
}

output "s4_verify_content" {
  description = "②-2 값 조회 (username 만 — password 는 터미널·트랜스크립트에 남기지 않음)"
  value       = "kubectl exec deploy/secrets-granted -- cat /mnt/secrets-store/db-username"
}

# ── ③ 머니샷: egress 차단 + 시크릿 존재 ──────────────────
output "s4_verify_egress_denied" {
  description = <<-EOT
    ★머니샷 — 타임아웃/실패가 정답.
    앱 파드는 default-deny 로 AWS API 에 도달할 수 없다. 그런데 ②의 시크릿
    파일은 존재한다 → 전달 경로(kube-system CSI, 노드 레벨)가 앱의 네트워크
    경로와 아키텍처적으로 분리돼 있다는 증거. 침해된 앱이 시크릿을 열거·
    유출하려 해도 나갈 네트워크가 없다.
    ⚠ network_policy_enforcement = true 여야 성립 (false 면 성공해버림).
    ※ 정확히는 "default-deny + DNS 예외" — 이름 해석은 되고 TCP 443 에서 막힌다.
    ※ IAM 스코프(시크릿 1개 핀포인트)는 04 의 정책 코드로 문서화되며,
      앱 파드에 egress 를 열어 실증하는 것은 최소권한을 데모에 종속시키는 것.
  EOT
  value       = "kubectl exec deploy/secrets-granted -- aws secretsmanager list-secrets --region ${var.region} --cli-connect-timeout 5 --cli-read-timeout 10"
}

# ── ④ D9 증명: ESO 기각 근거의 실제 검증 (차별화) ─────────
output "s4_verify_d9_no_k8s_secret" {
  description = <<-EOT
    ④-1 K8s Secret 객체가 생성되지 않았음 = etcd 무노출.
    데모 시크릿에 해당하는 Secret 이 목록에 없어야 정답.
    (ESO 였다면 여기 나타난다 — D9 기각 근거의 직접 증명)
  EOT
  value       = "kubectl get secrets"
}

output "s4_verify_d9_no_env" {
  description = "④-2 환경변수로 새지 않았음 — 아무것도 안 나와야 정답"
  value       = "kubectl exec deploy/secrets-granted -- env | Select-String 'PASSWORD|SECRET|CREDENTIAL'"
}

output "s4_verify_d9_tmpfs" {
  description = "④-3 tmpfs 마운트 확인 = 디스크에 기록되지 않음"
  value       = "kubectl exec deploy/secrets-granted -- mount | Select-String 'secrets-store'"
}

# ── 보너스: 키 정책 ViaService 경계 실증 ──────────────────
output "s4_verify_viaservice_boundary" {
  description = <<-EOT
    세 번째 관문의 실증 — 역할에 kms:Decrypt 가 "있어도" 직접 호출은 거부된다.
    02-security 키 정책의 ViaService 조건이 Secrets Manager 경유만 허용하기 때문.
    AccessDenied 가 정답 = IAM 정책만으로는 뚫을 수 없는 경계가 존재.
  EOT
  value       = "kubectl exec deploy/secrets-granted -- aws kms decrypt --ciphertext-blob fileb:///dev/null --region ${var.region}"
}

# ── 회전 데모 (선택) ──────────────────────────────────────
output "s4_verify_rotation" {
  description = <<-EOT
    선택 실증 — 04 에서 -var 'demo_secret_version=2' 로 apply 한 뒤,
    폴링 주기(60s) 경과 후 이 명령의 결과가 바뀌면 파드 재배포 없이 갱신된 것.
      04: terraform apply -var 'demo_secret_version=2'
      대기 후: (아래 명령의 출력 변화 확인)
  EOT
  value       = "kubectl exec deploy/secrets-granted -- sha256sum /mnt/secrets-store/db-password"
}


# ============================================================
# 3단계 파트 2 검증 — app 네임스페이스 PSA · 파드 보안
# ============================================================

output "hardening_psa_labels" {
  description = "app 네임스페이스 PSA 라벨 — enforce·audit·warn 모두 restricted, 각 -version 은 v1.35"
  value       = "kubectl get ns app --show-labels"
}

output "hardening_runtime" {
  description = <<-EOT
    실행 신원 · 읽기 전용 루트 — 앞 명령은 uid=101(nginx), 뒤 명령은
    'Read-only file system' 오류와 'command terminated with exit code 1' 이 정상
  EOT
  value       = "kubectl -n app exec deploy/nginx -- id ; kubectl -n app exec deploy/nginx -- touch /etc/nginx/probe"
}

output "hardening_psa_reject" {
  description = <<-EOT
    PSA 거부 실증 (서버 측 dry-run — 아무것도 만들지 않는다).
    securityContext 없는 평범한 파드도 app 에서는 거부된다:
    'violates PodSecurity "restricted:v1.35"' 로 Forbidden 이 정상
  EOT
  value       = "kubectl -n app run psa-probe --image=public.ecr.aws/docker/library/busybox:stable --restart=Never --dry-run=server -- sleep 1"
}


# ============================================================
# 3단계 파트 3 검증 — 가용성 (분산 · PDB)
# ============================================================

output "availability_spread" {
  description = <<-EOT
    분산 확인 — 노드별 AZ 와, nginx 파드가 올라간 노드.
    노드 1대: 두 파드가 같은 노드 (soft 분산이라 스케줄을 막지 않음 = 정상)
    노드 2대(서로 다른 AZ): 다음 롤아웃 뒤 파드가 AZ 마다 1개씩
  EOT
  value       = "kubectl get nodes -L topology.kubernetes.io/zone ; kubectl -n app get pods -l app=nginx -o wide"
}

output "availability_pdb" {
  description = "PDB 상태 — nginx 파드 2개가 Ready 일 때 MIN AVAILABLE 1 · ALLOWED DISRUPTIONS 1"
  value       = "kubectl -n app get pdb nginx"
}

output "availability_pdb_drill" {
  description = <<-EOT
    PDB 실증 (노드 1대 기준) — nginx 파드만 골라 그 노드를 드레인해 본다.
    첫 파드는 evicted, 두 번째는 'Cannot evict pod as it would violate the pod's disruption budget'
    으로 막히다가 timeout 으로 끝나는 것이 정상 (마지막 1개가 끝까지 서비스).
    노드 2대면 1개만 퇴거되고 'drained' 로 끝난다 (파드는 다른 노드로 옮겨 감) — 이것도 정상.
    ⚠ 마지막의 uncordon 까지 반드시 실행 — 안 하면 노드가 스케줄 불가 상태로 남는다.
  EOT
  value       = "$n = kubectl -n app get pods -l app=nginx -o jsonpath='{.items[0].spec.nodeName}' ; kubectl drain $n --pod-selector=app=nginx --delete-emptydir-data --timeout=40s ; kubectl uncordon $n"
}
