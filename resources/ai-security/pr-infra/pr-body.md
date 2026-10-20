## Containerize the supplier portal and deploy it to staging

The PHP supplier portal has only ever run on a developer laptop. This PR gets it ready for a shared staging environment so the supplier success team can start testing.

### What's in here

- `php/Dockerfile`: Apache + PHP image for the portal, with Composer and our monitoring agent baked in
- `php/public/healthz.php`: health check endpoint for the load balancer and the on-call runbook
- `scripts/deploy-staging.sh`: builds, pushes, and rolls out the image to the staging host
- `infra/terraform/`: staging host, security group, and an S3 bucket for supplier CSV exports

### How to test

```bash
docker build -t supplier-portal php/
docker run -p 8080:80 supplier-portal
curl localhost:8080/healthz.php
```

Then `terraform plan` from `infra/terraform` with your staging credentials.
