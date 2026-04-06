# Deployment Rollback — Step-by-Step Demo

---

## Setup

Apply the deployment first:
```bash
kubectl apply -f deployment.yaml
kubectl get pods -w
```

---

## Step 1 — Check Initial State

```bash
# What image is running right now?
kubectl describe deployment nginx-deployment | grep Image

# How many rollout revisions exist?
kubectl rollout history deployment/nginx-deployment
```

Expected:
```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:alpine
```

---

## Step 2 — Trigger a Rolling Update

Update the image and record the change reason:

```bash
kubectl set image deployment/nginx-deployment nginx=nginx:1.25
```

Annotate the reason (this appears in `rollout history`):
```bash
kubectl annotate deployment/nginx-deployment \
  kubernetes.io/change-cause="Updated nginx from alpine to 1.25" \
  --overwrite
```

Watch it happen:
```bash
kubectl rollout status deployment/nginx-deployment
```

Expected output:
```
Waiting for deployment "nginx-deployment" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deployment" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deployment" rollout to finish: 1 old replicas are pending termination...
deployment "nginx-deployment" successfully rolled out
```

---

## Step 3 — Check New State

```bash
# Confirm new image
kubectl describe deployment nginx-deployment | grep Image

# Check history (should now show 2 revisions)
kubectl rollout history deployment/nginx-deployment
```

Expected:
```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:alpine
2         Updated nginx from alpine to 1.25
```

---

## Step 4 — Simulate a Bad Deploy

Push a version that does NOT exist (to simulate a broken deployment):

```bash
kubectl set image deployment/nginx-deployment nginx=nginx:DOES-NOT-EXIST
kubectl annotate deployment/nginx-deployment \
  kubernetes.io/change-cause="Bad deploy — wrong image tag" \
  --overwrite
```

Watch what happens:
```bash
kubectl get pods -w
```

Pods will show `ImagePullBackOff` or `ErrImagePull`:
```
nginx-deployment-xxx   0/1   ErrImagePull    0   10s
```

The Deployment DOES NOT kill your existing pods until the new ones are healthy.  
**This is why `maxUnavailable: 0` matters — your old version keeps serving traffic.**

---

## Step 5 — Rollback to Last Known Good

```bash
# Roll back to the previous revision
kubectl rollout undo deployment/nginx-deployment

# Watch recovery
kubectl get pods -w
kubectl rollout status deployment/nginx-deployment
```

Expected:
```
deployment "nginx-deployment" successfully rolled out
```

---

## Step 6 — Rollback to a Specific Revision

```bash
# See all revisions
kubectl rollout history deployment/nginx-deployment

# Go back to revision 1 specifically
kubectl rollout undo deployment/nginx-deployment --to-revision=1

# Confirm which image is now running
kubectl describe deployment nginx-deployment | grep Image
```

---

## Key Takeaways

| Concept | Command |
|---|---|
| See history | `kubectl rollout history deployment/<name>` |
| Trigger update | `kubectl set image deployment/<name> <container>=<new-image>` |
| Watch progress | `kubectl rollout status deployment/<name>` |
| Rollback (last) | `kubectl rollout undo deployment/<name>` |
| Rollback (specific) | `kubectl rollout undo deployment/<name> --to-revision=N` |
| Pause rollout | `kubectl rollout pause deployment/<name>` |
| Resume rollout | `kubectl rollout resume deployment/<name>` |
