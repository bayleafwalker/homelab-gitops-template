# Registry access and node image-pulls

This document explains long-term and short-term steps to ensure nodes and pods can reach your private registry.

Background
- Kubernetes image pulls are performed by the kubelet on each node (host network). Cluster NetworkPolicies do not affect node-level (kubelet) egress.

Long-term recommendations
- Ensure your nodes can reach the registry LoadBalancer IP/port.
	- In this repo, the in-cluster registry exposes a dedicated LoadBalancer endpoint at `${REGISTRY_IP}:5000` via `registry/docker-registry-lb`.
	- If you migrate the registry to a new IP/VLAN, you can keep both the new `${REGISTRY_IP}:5000` mirror and the previous endpoint (e.g. `192.168.1.21:5000`) configured side-by-side for rollback compatibility until the migration is verified.
	- If you see kubelet/containerd errors like `http: server gave HTTP response to HTTPS client`, the node runtime is still trying HTTPS and needs an insecure-registry configuration.
- Prefer the LoadBalancer endpoint for kubelet pulls (containerd does not support Authentik forward-auth at the HTTP route host `registry.example.com`).
	- Use authenticated registries and `imagePullSecrets` where appropriate.

Node runtime / TLS guidance
- If your registry is HTTP (no TLS) you will see errors like "http: server gave HTTP response to HTTPS client". Kubelet/containerd by default expects HTTPS for registry endpoints.

Two reasonable fixes (choose one):

1) Secure the registry with TLS (recommended)
	- Configure your registry to serve HTTPS with a valid certificate signed by a CA trusted by the nodes, or add the CA to the node trust store.
	- Verify with: `curl -v http://${REGISTRY_IP}:5000/v2/` from a node (hostNetwork debug pod).

2) Configure the container runtime to allow an insecure registry (node-level change)
	- For Talos nodes in this repo, the intended long-term fix is already expressed as a Talos patch: `clusters/main/talos/patches/registry.yaml` (mirrors `${REGISTRY_IP}:5000` to `http://${REGISTRY_IP}:5000`).
	- If nodes are still failing pulls, regenerate and apply the machine config to the nodes.

Apply on Talos (typical workflow)
```bash
# 1) Generate machine configs (use your existing generation workflow/tooling)
#    See docs/operations.md for the canonical steps.

# 2) Apply to each node (example — adjust node IPs)
talosctl --talosconfig clusters/talosconfig apply-config --insecure --nodes 192.168.1.11 --file clusters/main/talos/generated/main-k8s-control-1.yaml
talosctl --talosconfig clusters/talosconfig apply-config --insecure --nodes 192.168.1.12 --file clusters/main/talos/generated/main-k8s-worker-1.yaml

# 3) Restart kubelet/containerd by rebooting the node if needed
talosctl --talosconfig clusters/talosconfig reboot --nodes 192.168.1.11
talosctl --talosconfig clusters/talosconfig reboot --nodes 192.168.1.12
```

Containerd example (non-Talos reference)
	- For vanilla containerd, configure a mirror endpoint for the registry LoadBalancer over HTTP and restart containerd. Example snippet:

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
	 [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY_IP}:5000"]
		endpoint = ["http://${REGISTRY_IP}:5000"]
```

	- On Talos-managed nodes update the Talos config (see `clusters/main/talos/talconfig.json`) or follow your distribution's containerd configuration method; then restart containerd/kubelet.

Notes on temporary workarounds
- Patching `Deployment` pod templates to schedule on a node that can reach the registry or adding pod-level NetworkPolicies are workarounds only. The real fix is to make nodes able to pull images reliably (TLS or runtime config).

Temporary measures (pod-level only)
- You can temporarily allow pod egress to the registry IP from affected namespaces while you fix node-level networking. This does NOT fix kubelet ImagePullBackOff.

Debugging commands (run locally using kubeconfig)
```bash
# check from hostNetwork debug pod (runs on node network)
kubectl -n kube-system exec hostnet-debug-control -- curl -v --max-time 10 http://${REGISTRY_IP}:5000/v2/ || true

# check from a worker
kubectl -n kube-system exec hostnet-debug-worker -- curl -v --max-time 10 http://${REGISTRY_IP}:5000/v2/ || true

# traceroute from a node (if available in debug pod)
kubectl -n kube-system exec hostnet-debug-control -- traceroute -w 2 ${REGISTRY_IP} || true
```

Cleanup
- After nodes can reach the registry, remove any temporary pod-level NetworkPolicies and keep the permanent network/firewall or mirror solution.
