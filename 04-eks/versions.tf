terraform {
  # ~> 1.14.0 (패치만 허용). 하한만 두면 로컬이 CI 보다 먼저 올라갈 수 있고, 높은 버전이 쓴 state 는 낮은 버전이 못 읽어 CI plan 이 깨진다.
  # 올릴 땐 CI 먼저. 기술적 최소 요건은 write-only 인자가 생긴 1.11.
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.50: Secrets Manager write-only 인자 관련 수정 포함
      version = ">= 6.50, < 7.0"
    }
    # ephemeral "random_password" — 값이 state 에 남지 않는 생성기
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
