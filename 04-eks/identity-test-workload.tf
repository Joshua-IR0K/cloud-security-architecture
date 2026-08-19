# ============================================================
# 04-eks/identity-test-workload.tf — 앱 워크로드 Pod Identity 실증 (Stage 2)
# ============================================================
# BREAK → BUILD → VERIFY (순서가 곧 서사):
#   ① identity-denied (SA 역할 없음) 에서 S3 호출 → 자격증명 부재로 실패
#      = "기본 거부" + hop-limit=1(노드롤 IMDS 폴백 차단) 이중 실증
#      ⚠ 이게 "성공"하면 그게 더 큰 문제 — IMDS 경로가 열려 노드롤을
#        상속했다는 뜻 (hop-limit 설정을 의심할 것)
#   ② 전용 미니 버킷 + 그 버킷 "하나"로 스코프된 역할 + Pod Identity 연결
#   ③ identity-granted: 대상 버킷 ls 성공 / 전체 버킷 목록 → AccessDenied
#
# 배치 결정(확정): 리소스 전부 04(destroyable) — 클린 리빌드 때 함께 소멸.
#   영속 스택(02)에 데모 의존성을 만들지 않음.
# ============================================================

# ── 데모 대상: 전용 미니 S3 버킷 ──────────────────────────
resource "aws_s3_bucket" "identity_demo" {
  # 버킷명은 글로벌 유일 — 계정 ID suffix 로 결정론적 유일성 확보
  bucket        = "${var.project_name}-s2-identity-demo-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # 데모 객체가 남아 있어도 destroy 가능 (사이클 규율)
}

resource "aws_s3_bucket_public_access_block" "identity_demo" {
  bucket                  = aws_s3_bucket.identity_demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "identity_demo_hello" {
  bucket  = aws_s3_bucket.identity_demo.id
  key     = "hello-from-stage2.txt"
  content = "pod identity works - scoped to this bucket only\n"
}

# ── 앱 역할: 버킷 1개 읽기로 핀포인트 (LBC 최소권한과 같은 철학, D13) ──
data "aws_iam_policy_document" "identity_demo_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

data "aws_iam_policy_document" "identity_demo_read" {
  statement {
    sid       = "ListTargetBucketOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.identity_demo.arn]
  }
  statement {
    sid       = "GetObjectsInTargetBucketOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.identity_demo.arn}/*"]
  }
  # 의도적 부재: s3:ListAllMyBuckets
  #   → "aws s3 ls"(전체 목록)는 AccessDenied = 스코프 증명의 세 번째 축
}

resource "aws_iam_role" "identity_demo" {
  name               = "${var.cluster_name}-s2-identity-demo"
  assume_role_policy = data.aws_iam_policy_document.identity_demo_trust.json
}

resource "aws_iam_role_policy" "identity_demo" {
  name   = "s3-read-single-bucket"
  role   = aws_iam_role.identity_demo.id
  policy = data.aws_iam_policy_document.identity_demo_read.json
}

# 앱 워크로드용 연결 — LBC(인프라 컴포넌트, lb-controller.tf)와 목적 구분
resource "aws_eks_pod_identity_association" "identity_demo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "s2-identity-demo"
  role_arn        = aws_iam_role.identity_demo.arn
}

# ── K8s: SA + 파드 2개 (denied / granted) ─────────────────
resource "kubernetes_service_account_v1" "identity_demo" {
  metadata {
    name      = "s2-identity-demo"
    namespace = "default"
  }
}

locals {
  # latest 사용 근거: S2 한정 데모 파드(사이클마다 소멸)라 digest 핀 원칙(D11)의
  # 적용 대상인 "서비스 워크로드"가 아님 — S5(ECR)·S7(서명/검증)에서 본편 적용.
  awscli_image = "public.ecr.aws/aws-cli/aws-cli:latest"
}

# ⚠ Stage 3 에서 bare Pod → Deployment 로 전환 (D23)
#   이유 1 (강제): NetworkPolicy 는 ownerReferences 가 있는 파드에만 적용됨.
#     standalone Pod 은 정책 대상이 되지 않아 세그멘테이션 실증이 불가능.
#   이유 2 (개선): 트러블슈팅 #7(Pod Identity admission-time 주입 레이스)의
#     복구가 `kubectl rollout restart deploy/...` 한 줄로 끝남
#     (bare Pod 은 delete → terraform apply 왕복이 필요했음).
#   ※ 검증 명령도 파드명 대신 `deploy/<name>` 참조로 변경됨 (outputs.tf)

resource "kubernetes_deployment_v1" "identity_denied" {
  metadata {
    name      = "identity-denied"
    namespace = "default"
    labels    = { app = "s2-demo", role = "denied" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "s2-demo", role = "denied" }
    }
    template {
      metadata {
        labels = { app = "s2-demo", role = "denied" }
      }
      spec {
        # service_account_name 미지정 = default SA = Pod Identity 연결 없음 (의도)
        container {
          name    = "awscli"
          image   = local.awscli_image
          command = ["sleep", "infinity"]
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_deployment_v1" "identity_granted" {
  metadata {
    name      = "identity-granted"
    namespace = "default"
    labels    = { app = "s2-demo", role = "granted" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "s2-demo", role = "granted" }
    }
    template {
      metadata {
        labels = { app = "s2-demo", role = "granted" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.identity_demo.metadata[0].name
        container {
          name    = "awscli"
          image   = local.awscli_image
          command = ["sleep", "infinity"]
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }

  # 연결이 파드보다 먼저 존재해야 admission-time 에 자격이 주입됨.
  # 그래도 전파 지연 레이스(#7)는 남으므로, NoCredentials 시:
  #   kubectl rollout restart deploy/identity-granted
  depends_on = [aws_eks_pod_identity_association.identity_demo]
}
