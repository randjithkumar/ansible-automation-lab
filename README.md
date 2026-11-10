# Ansible Automation Lab

Hands-on automation for Linux provisioning and Spring Boot deployment using Ansible, reusable roles, Vault, execution environments, health checks, and configuration rollback.

## Project status

This is a learning lab, not a production-ready deployment framework. The exercises have been run against a local Ubuntu VM. Automation Platform integration and the future seven-microservice deployment are planned work.

## Lab architecture

| Component | Purpose |
| --- | --- |
| Windows host with VirtualBox | Runs the two Linux VMs |
| Original Ubuntu VM | Build tools, Ansible, Podman, Git, and temporary artifact server |
| Managed Ubuntu clone | Java runtime, application account, cron, and Spring Boot service |
| Execution environment | Containerized Ansible runtime built using Ansible Builder |

Example host-only addresses are `192.168.56.102` for the control VM and `192.168.56.101` for the managed VM. Change inventories and artifact URLs to match your environment. The development and test inventories currently target the same VM; they are alternative configurations, not isolated environments.

## Repository layout

```text
.
|-- remote-check.yml                     # Provision and deploy the application
|-- rollback-config.yml                  # Restore a known-good configuration
|-- first-playbook.yml                   # Foundation exercises
|-- check-playbooks.sh                   # Syntax and lint checks
|-- ee-check.yml                         # Local execution-environment smoke test
|-- ee/execution-environment.yml         # Container runtime definition
|-- inventories/
|   |-- dev/hosts.ini
|   |-- dev/group_vars/managed.yml
|   |-- test/hosts.ini
|   `-- test/group_vars/managed.yml
|-- roles/cron_service/tasks/main.yml
|-- templates/
|   |-- application.yml.j2
|   `-- deployed-application.yml.j2
|-- vault/demo.yml                       # Encrypted dummy variable
|-- vault-check.yml                      # Validate decryption without printing value
|-- vault-deploy.yml                     # Deploy a protected dummy-secret file
`-- inventory.ini                       # Original foundation inventory
```

Generated build files, application JARs, artifact-server files, caches, and local credentials are excluded from Git. The sample application source is maintained separately from the staged automation files.

## Prerequisites

- Two reachable Linux VMs with distinct SSH host identities.
- SSH key authentication from the control VM to the managed account.
- Sudo access on the managed account.
- Ansible, Ansible Lint, and Bash for direct execution and quality checks.
- Podman and Ansible Builder for containerized execution.
- A built Spring Boot JAR, an accessible artifact URL, and its SHA-256 checksum.
- The Vault password for encrypted-variable exercises; obtain it separately from the repository.

The lab used Ansible Core 2.20.1, Ansible Builder 3.2.0, and Java 21. Consult `ee/execution-environment.yml` for the selected image dependencies. The image does not fully lock every transitive dependency.

## Configure your environment

Update the selected inventory with the target address and login account. Adjust the SSH key path if necessary.

Example development group variables:

```yaml
---
app_name: "ansible-demo"
app_port: 9090
app_version: "1.0.0"
app_artifact_url: "http://192.168.56.102:8000/{{ app_version }}/ansible-demo.jar"
app_artifact_sha256: "REPLACE_WITH_THE_64_CHARACTER_SHA256_HASH"
```

The checksum variable contains only the hash. The download task adds the `sha256:` prefix. Configure artifact variables in both environment files before using the deployment playbook.

The Ubuntu lab uses `ansible_become_exe=/usr/bin/sudo.ws` to work around a privilege-escalation issue encountered with sudo-rs. Keep this setting only on targets where that executable exists and is required.

## Publish the lab artifact

On the control VM, place the separately built JAR under a versioned directory:

```bash
mkdir -p artifacts/1.0.0
cp /path/to/built-application.jar artifacts/1.0.0/ansible-demo.jar
sha256sum artifacts/1.0.0/ansible-demo.jar
```

Use the resulting hash in the group variables, then start the temporary server:

```bash
python3 -m http.server 8000 --bind 192.168.56.102 --directory "$PWD/artifacts"
```

Keep it running during deployment. This plain HTTP server is for the private lab. A production setup needs an appropriately secured artifact repository. A checksum verifies the expected bytes; its trust depends on protecting the expected checksum too.

## Quality checks

From the repository root:

```bash
bash check-playbooks.sh
```

The script checks the main playbook syntax and lints the main playbook and cron role. It does not execute a deployment or validate every file in the repository. Passing the linter's production profile does not establish production readiness.

## Deploy directly

```bash
ansible-playbook -i inventories/dev/hosts.ini remote-check.yml --ask-become-pass
```

The playbook validates the port, provisions the account and directories, manages cron, installs Java, downloads and verifies the JAR, deploys configuration and a systemd unit, runs notified restart handlers, and checks application health.

Verify access from the control VM:

```bash
curl -i http://192.168.56.101:9090/actuator/health
```

Expect HTTP 200 and a JSON status of `UP`. A routine rerun should avoid unnecessary application changes and restarts; package-cache refreshes can still report changes.

## Preview an alternative configuration

```bash
ansible-playbook -i inventories/test/hosts.ini remote-check.yml --ask-become-pass --check --diff
```

Check mode is a prediction, not a successful deployment test. Some tasks are skipped. The cron assertion is intentionally skipped in check mode. Diff output can reveal file contents; avoid using it on unprotected secret tasks.

## Build and use the execution environment

```bash
cd ee
~/.local/bin/ansible-builder build -f execution-environment.yml --container-runtime podman --tag localhost/ansible-lab-ee:1.0
cd ..
podman run --rm localhost/ansible-lab-ee:1.0 ansible --version
```

Run the deployment through the image from the repository root:

```bash
podman run --rm -it \
  --userns=keep-id \
  -e HOME=/runner \
  -v "$PWD:/runner/project:ro" \
  -v "$HOME/.ssh:/runner/.ssh:ro" \
  -w /runner/project \
  localhost/ansible-lab-ee:1.0 \
  ansible-playbook \
    -i inventories/dev/hosts.ini remote-check.yml \
    --ask-become-pass \
    -e ansible_ssh_private_key_file=/runner/.ssh/id_ed25519 \
    -e '{"ansible_ssh_common_args":"-o UserKnownHostsFile=/runner/.ssh/known_hosts"}'
```

Verify and trust the target host fingerprint before this run. Project and SSH files are supplied through read-only mounts, not embedded in the image. A passphrase-protected key may require separately configured agent access; do not remove its protection to bypass an authentication failure.

## Vault exercises

```bash
ansible-playbook -i localhost, vault-check.yml --ask-vault-pass
ansible-playbook -i inventories/dev/hosts.ini vault-deploy.yml --ask-vault-pass --ask-become-pass
EDITOR=nano ansible-vault edit vault/demo.yml
```

The Vault password decrypts source variables; the become password authorizes remote sudo. They serve different purposes. The practice token is a dummy value and is not consumed by the application.

Vault protects stored source content. A deployed secret file is plaintext unless separately encrypted. The lab protects that file with root ownership and mode `0600`, and suppresses sensitive task logs and diffs. Never commit Vault passwords, SSH private keys, or real plaintext credentials.

## Configuration rollback

Rollback requires an existing, verified snapshot on the managed server:

```text
/opt/ansible-demo/application-9090.known-good.yml
```

With the application healthy on port 9090, create the snapshot once:

```bash
ansible managed -i inventories/dev/hosts.ini --become --ask-become-pass \
  -m ansible.builtin.copy \
  -a 'src=/opt/ansible-demo/application.yml dest=/opt/ansible-demo/application-9090.known-good.yml remote_src=true owner=root group=ansible_demo mode=0644 force=false'
```

Restore it when needed:

```bash
ansible-playbook -i inventories/dev/hosts.ini rollback-config.yml --ask-become-pass
```

The recovery playbook restores configuration, deliberately restarts the application, and verifies health on port 9090. It does not restore an older JAR, database state, or service definition. Ansible does not automatically undo tasks when a later task fails.

## Troubleshooting

On the managed VM:

```bash
sudo systemctl status ansible-demo --no-pager -l
sudo journalctl -u ansible-demo -n 60 --no-pager
sudo ss -ltnp
cat /opt/ansible-demo/application.yml
```

Check task order: artifact and configuration deployment must precede the handler flush, and health verification must follow the restart. Connection refused can indicate a stopped application, a different listening port, or a startup failure. Interpreter-discovery warnings are separate from task failures.

## Planned work

- Git-hosted project and artifact-registry integration with Automation Platform.
- Platform credentials, execution-environment registration, job templates, workflows, and access controls.
- Additional incident exercises and artifact-version rollback.
- Repository review and deployment automation for seven communicating microservices.

The current lab artifact URL is reachable on the VirtualBox host-only network. A platform execution host needs its own network path to the managed server and artifact repository. Platform access and installation are not included in the current two-VM setup.
