# AWS Infrastructure for GitHub Actions

This directory contains CloudFormation templates for setting up AWS access from GitHub Actions.

## Prerequisites

- AWS CLI configured with your sandbox profile
- Bedrock models are auto-enabled on first use (no manual setup needed)

## Deploy OIDC + Bedrock Role

```bash
# Deploy the stack
aws cloudformation deploy \
  --template-file github-oidc-bedrock.yml \
  --stack-name github-oidc-bedrock \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile sandbox

# Get the role ARN (needed for GitHub workflow)
aws cloudformation describe-stacks \
  --stack-name github-oidc-bedrock \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text \
  --profile sandbox
```

## What This Creates

1. **OIDC Identity Provider**: Allows GitHub Actions to authenticate with AWS
2. **IAM Role**: `GitHubActionsBedrockRole` with permissions to:
   - Invoke Bedrock models (Claude, Llama, Mistral)
   - List available models

## Security

- The role can ONLY be assumed by GitHub Actions running in `andreasronge/ptc_runner`
- No long-lived credentials are stored in GitHub
- Permissions are scoped to Bedrock invoke only

## Cleanup

```bash
aws cloudformation delete-stack \
  --stack-name github-oidc-bedrock \
  --profile sandbox
```
