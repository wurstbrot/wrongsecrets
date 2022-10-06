helm list | grep 'vault' &>/dev/null
if [ $? == 0 ]; then
  echo "Vault is already installed"
else
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo update hashicorp
  helm upgrade --install vault hashicorp/vault --version 0.22.0 --values ../k8s/helm-vault-values.yml
fi

isvaultrunning=$(kubectl get pods --field-selector=status.phase=Running)
while [[ $isvaultrunning != *"vault-0"* ]]; do echo "waiting for Vault0" && sleep 2 && isvaultrunning=$(kubectl get pods --field-selector=status.phase=Running); done
while [[ $isvaultrunning != *"vault-1"* ]]; do echo "waiting for Vault1" && sleep 2 && isvaultrunning=$(kubectl get pods --field-selector=status.phase=Running); done
while [[ $isvaultrunning != *"vault-2"* ]]; do echo "waiting for Vault2" && sleep 2 && isvaultrunning=$(kubectl get pods --field-selector=status.phase=Running); done

echo "Setting up port forwarding"
kubectl port-forward vault-0 8200:8200 &
echo "Unsealing Vault"
kubectl exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json
cat cluster-keys.json | jq -r ".unseal_keys_b64[]"
VAULT_UNSEAL_KEY=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[]")

echo "⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰⏰"
echo "PLEASE COPY PASTE THE FOLLOWING VALUE: $VAULT_UNSEAL_KEY, you will be asked for it 3 times to unseal the vaults"

kubectl exec -it vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY
kubectl exec -it vault-1 -- vault operator unseal $VAULT_UNSEAL_KEY
kubectl exec -it vault-2 -- vault operator unseal $VAULT_UNSEAL_KEY

echo "Obtaining root token"
jq .root_token cluster-keys.json >commentedroottoken

sed "s/^\([\"']\)\(.*\)\1\$/\2/g" commentedroottoken >root_token
ROOTTOKEN=$(cat root_token)

echo "Logging in"
kubectl exec vault-0 -- vault login $ROOTTOKEN

echo "Enabling kv-v2 kubernetes"
kubectl exec vault-0 -- vault secrets enable -path=secret kv-v2

echo "Putting a secret in"
kubectl exec vault-0 -- vault kv put secret/secret-challenge vaultpassword.password="$(openssl rand -base64 16)"

echo "Enable k8s auth"
kubectl exec vault-0 -- vault auth enable kubernetes

echo "Writing k8s auth config"

kubectl exec vault-0 -- /bin/sh -c 'vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'

echo "Writing policy for secret-challenge"
kubectl exec vault-0 -- /bin/sh -c 'vault policy write secret-challenge - <<EOF
path "secret/data/secret-challenge" {
  capabilities = ["read"]
}
path "secret/data/application" {
  capabilities = ["read"]
}
EOF'

echo "Write secrets for secret-challenge"
kubectl exec vault-0 -- vault write auth/kubernetes/role/secret-challenge \
  bound_service_account_names=vault \
  bound_service_account_namespaces=default \
  policies=secret-challenge \
  ttl=24h &&
  vault kv put secret/secret-challenge vaultpassword.password="$(openssl rand -base64 16)" &&
  vault kv put secret/application vaultpassword.password="$(openssl rand -base64 16)"
