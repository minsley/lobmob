# Claude Code Agent Cluster - GitHub Access Architecture

## System Overview

This system manages GitHub repository access for a Kubernetes-based cluster of Claude Code agents. The architecture uses:

- **Setup Wizard**: Programmatic GitHub App creation with user interaction
- **Lobwife**: Credential broker service (K8s deployment)
- **Lobsters**: Claude Code agent workers (K8s pods)
- **Token Flow**: Short-lived, repository-scoped installation tokens with automatic refresh

## Architecture Components

```
┌─────────────┐
│ Setup Wizard│──┐
└─────────────┘  │ (creates GitHub App)
                 ↓
         ┌──────────────┐
         │  GitHub API  │
         └──────────────┘
                 ↑
                 │ (requests tokens)
         ┌──────────────┐
         │   Lobwife    │←─────────┐
         │   (Broker)   │          │
         └──────────────┘          │
                 ↑                 │
                 │ (token requests)│ (refresh requests)
         ┌──────────────┐          │
         │   Lobster    │──────────┘
         │   (Agent)    │
         └──────────────┘
                 │
                 ↓
         ┌──────────────┐
         │  Git Repos   │
         └──────────────┘
```

---

## 1. Setup Wizard: GitHub App Creation

### Manifest-Based Flow

The setup wizard guides users through GitHub App creation using the manifest API.

### Wizard Implementation

```python
# setup_wizard.py
import json
import base64
from flask import Flask, redirect, request, session
import requests

app = Flask(__name__)
app.secret_key = 'your-secret-key'

@app.route('/setup/start')
def start_setup():
    """Step 1: Collect configuration"""
    return render_template('setup_form.html')

@app.route('/setup/create-app', methods=['POST'])
def create_github_app():
    """Step 2: Generate manifest and redirect to GitHub"""
    
    org_name = request.form['org_name']
    webhook_url = request.form.get('webhook_url', 
                                    'https://lobwife.your-cluster.com/webhook')
    
    # Generate GitHub App manifest
    manifest = {
        "name": f"Claude Cluster - {org_name}",
        "url": "https://your-cluster-dashboard.com",
        "hook_attributes": {
            "url": webhook_url
        },
        "redirect_url": f"{request.host_url}setup/callback",
        "public": False,
        "default_permissions": {
            "contents": "write",
            "pull_requests": "write",
            "metadata": "read"
        },
        "default_events": ["push", "pull_request"]
    }
    
    # Store org name for callback
    session['org_name'] = org_name
    
    # Encode and redirect
    encoded = base64.b64encode(json.dumps(manifest).encode()).decode()
    return redirect(f"https://github.com/settings/apps/new?manifest={encoded}")

@app.route('/setup/callback')
def github_callback():
    """Step 3: Receive app credentials from GitHub"""
    
    code = request.args.get('code')
    if not code:
        return "Error: No code received", 400
    
    # Exchange code for credentials
    response = requests.post(
        f"https://api.github.com/app-manifests/{code}/conversions",
        headers={'Accept': 'application/vnd.github.v3+json'}
    )
    
    if response.status_code != 201:
        return f"Error creating app: {response.text}", 400
    
    credentials = response.json()
    
    # Store credentials in Kubernetes secrets
    store_credentials_in_k8s(
        app_id=credentials['id'],
        client_id=credentials['client_id'],
        client_secret=credentials['client_secret'],
        private_key=credentials['pem'],
        webhook_secret=credentials['webhook_secret']
    )
    
    return render_template('setup_complete.html', 
                          app_slug=credentials['slug'],
                          install_url=f"https://github.com/apps/{credentials['slug']}/installations/new")

def store_credentials_in_k8s(app_id, client_id, client_secret, private_key, webhook_secret):
    """Store GitHub App credentials in K8s secrets"""
    import subprocess
    import tempfile
    
    # Write private key to temp file
    with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.pem') as f:
        f.write(private_key)
        key_file = f.name
    
    # Create K8s secret
    subprocess.run([
        'kubectl', 'create', 'secret', 'generic', 'github-app-credentials',
        '--from-literal', f'app-id={app_id}',
        '--from-literal', f'client-id={client_id}',
        '--from-literal', f'client-secret={client_secret}',
        '--from-file', f'private-key={key_file}',
        '--from-literal', f'webhook-secret={webhook_secret}',
        '--namespace', 'lobster-cluster'
    ], check=True)
    
    # Clean up temp file
    import os
    os.unlink(key_file)
```

### Setup Wizard UI Flow

```
┌────────────────────────────────────────┐
│  Claude Cluster Setup                  │
├────────────────────────────────────────┤
│  Step 1: GitHub Access Configuration   │
│                                         │
│  Organization: [acme-corp__________]   │
│  Webhook URL: [auto-filled_________]   │
│                                         │
│  [ Create GitHub App ]                 │
└────────────────────────────────────────┘
              ↓
┌────────────────────────────────────────┐
│  GitHub.com                             │
│  Create "Claude Cluster - acme-corp"?  │
│  Permissions: contents, pull_requests  │
│  [ Cancel ]  [ Create GitHub App ]     │
└────────────────────────────────────────┘
              ↓
┌────────────────────────────────────────┐
│  Setup Complete!                        │
│  ✓ GitHub App created                  │
│  ✓ Credentials stored in cluster       │
│                                         │
│  Next: Install app to repositories     │
│  [ Open Installation Page ]            │
└────────────────────────────────────────┘
```

---

## 2. Lobwife: Credential Broker Service

### Overview

Lobwife is a K8s service that:
- Generates repository-scoped installation tokens
- Validates task-to-repo mappings
- Handles token refresh requests
- Provides audit logging

### Deployment

```yaml
# lobwife-deployment.yaml
apiVersion: v1
kind: Service
metadata:
  name: lobwife
  namespace: lobster-cluster
spec:
  selector:
    app: lobwife
  ports:
  - port: 8080
    targetPort: 8080
  type: ClusterIP

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lobwife
  namespace: lobster-cluster
spec:
  replicas: 2
  selector:
    matchLabels:
      app: lobwife
  template:
    metadata:
      labels:
        app: lobwife
    spec:
      containers:
      - name: lobwife
        image: your-registry/lobwife:latest
        ports:
        - containerPort: 8080
        env:
        - name: GITHUB_APP_ID
          valueFrom:
            secretKeyRef:
              name: github-app-credentials
              key: app-id
        - name: GITHUB_PRIVATE_KEY
          valueFrom:
            secretKeyRef:
              name: github-app-credentials
              key: private-key
        volumeMounts:
        - name: task-mappings
          mountPath: /config
      volumes:
      - name: task-mappings
        configMap:
          name: task-repo-mappings
```

### Lobwife Implementation

```python
# lobwife/server.py
from flask import Flask, request, jsonify
import jwt
import time
import requests
from datetime import datetime, timedelta
import os
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

# Load GitHub App credentials
GITHUB_APP_ID = os.environ['GITHUB_APP_ID']
GITHUB_PRIVATE_KEY = os.environ['GITHUB_PRIVATE_KEY'].replace('\\n', '\n')
INSTALLATION_ID = os.environ.get('GITHUB_INSTALLATION_ID')  # Set per org

# In-memory audit log (use persistent storage in production)
audit_log = []

def generate_jwt():
    """Generate GitHub App JWT for authentication"""
    payload = {
        'iat': int(time.time()),
        'exp': int(time.time()) + 600,  # 10 minutes
        'iss': GITHUB_APP_ID
    }
    return jwt.encode(payload, GITHUB_PRIVATE_KEY, algorithm='RS256')

def create_installation_token(repositories, permissions=None):
    """
    Generate installation token scoped to specific repositories
    
    Args:
        repositories: List of repo names (e.g., ['org/repo-a', 'org/repo-b'])
        permissions: Dict of permissions (default: contents:write, pull_requests:write)
    
    Returns:
        dict with 'token' and 'expires_at'
    """
    if permissions is None:
        permissions = {
            "contents": "write",
            "pull_requests": "write"
        }
    
    app_jwt = generate_jwt()
    
    # Extract repo names without org prefix for API
    repo_names = [repo.split('/')[-1] for repo in repositories]
    
    response = requests.post(
        f"https://api.github.com/app/installations/{INSTALLATION_ID}/access_tokens",
        headers={
            'Authorization': f'Bearer {app_jwt}',
            'Accept': 'application/vnd.github.v3+json'
        },
        json={
            'repositories': repo_names,
            'permissions': permissions
        }
    )
    
    if response.status_code != 201:
        raise Exception(f"Failed to create token: {response.text}")
    
    data = response.json()
    return {
        'token': data['token'],
        'expires_at': data['expires_at']
    }

@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({'status': 'healthy'})

@app.route('/credentials', methods=['POST'])
def get_credentials():
    """
    Generate credentials for a task
    
    Request body:
    {
        "task_id": "task-abc-123",
        "repos": ["org/repo-a", "org/repo-b"]
    }
    
    Returns:
    {
        "token": "ghs_...",
        "expires_at": "2024-01-01T12:00:00Z",
        "expires_in": 3600
    }
    """
    data = request.json
    task_id = data.get('task_id')
    repos = data.get('repos', [])
    
    if not task_id or not repos:
        return jsonify({'error': 'task_id and repos required'}), 400
    
    try:
        # Validate repos (optional: check against allowed list)
        validate_repo_access(task_id, repos)
        
        # Generate scoped token
        token_data = create_installation_token(repos)
        
        # Audit log
        log_entry = {
            'timestamp': datetime.utcnow().isoformat(),
            'task_id': task_id,
            'repos': repos,
            'action': 'token_created',
            'expires_at': token_data['expires_at']
        }
        audit_log.append(log_entry)
        logging.info(f"Token created for task {task_id}: {repos}")
        
        return jsonify({
            'token': token_data['token'],
            'expires_at': token_data['expires_at'],
            'expires_in': 3600
        })
    
    except Exception as e:
        logging.error(f"Error creating token for task {task_id}: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/credentials/refresh', methods=['POST'])
def refresh_credentials():
    """
    Refresh credentials for an active task
    
    Request body:
    {
        "task_id": "task-abc-123"
    }
    """
    data = request.json
    task_id = data.get('task_id')
    
    if not task_id:
        return jsonify({'error': 'task_id required'}), 400
    
    try:
        # Lookup task to get repos (from task DB or cache)
        task = get_task_info(task_id)
        
        if not task or task.get('status') != 'running':
            return jsonify({'error': 'Task not active'}), 403
        
        repos = task['repos']
        
        # Generate new token
        token_data = create_installation_token(repos)
        
        # Audit log
        log_entry = {
            'timestamp': datetime.utcnow().isoformat(),
            'task_id': task_id,
            'repos': repos,
            'action': 'token_refreshed',
            'expires_at': token_data['expires_at']
        }
        audit_log.append(log_entry)
        logging.info(f"Token refreshed for task {task_id}")
        
        return jsonify({
            'token': token_data['token'],
            'expires_at': token_data['expires_at'],
            'expires_in': 3600
        })
    
    except Exception as e:
        logging.error(f"Error refreshing token for task {task_id}: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/audit', methods=['GET'])
def get_audit_log():
    """Retrieve audit log entries"""
    task_id = request.args.get('task_id')
    
    if task_id:
        filtered = [entry for entry in audit_log if entry['task_id'] == task_id]
        return jsonify(filtered)
    
    return jsonify(audit_log[-100:])  # Last 100 entries

def validate_repo_access(task_id, repos):
    """Validate that task is allowed to access these repos"""
    # Implement your validation logic here
    # Could check against ConfigMap, database, etc.
    pass

def get_task_info(task_id):
    """Retrieve task information from task database"""
    # Implement task lookup
    # This should return task metadata including repos and status
    # For now, return mock data
    return {
        'task_id': task_id,
        'status': 'running',
        'repos': ['org/repo-a', 'org/repo-b']
    }

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

---

## 3. Lobster: Claude Code Agent Workers

### Deployment

```yaml
# lobster-deployment.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: lobster-task-${TASK_ID}
  namespace: lobster-cluster
spec:
  template:
    metadata:
      labels:
        app: lobster
        task: ${TASK_ID}
    spec:
      restartPolicy: Never
      containers:
      - name: lobster
        image: your-registry/lobster:latest
        env:
        - name: TASK_ID
          value: "${TASK_ID}"
        - name: TASK_REPOS
          value: "${TASK_REPOS}"
        - name: TASK_INSTRUCTIONS
          value: "${TASK_INSTRUCTIONS}"
        - name: LOBWIFE_URL
          value: "http://lobwife.lobster-cluster.svc.cluster.local:8080"
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: anthropic-credentials
              key: api-key
        volumeMounts:
        - name: skills
          mountPath: /home/claude/.claude/skills
      volumes:
      - name: skills
        configMap:
          name: lobster-skills
```

### Claude Skill: GitHub Token Management

```markdown
# github-token-manager/SKILL.md

# GitHub Token Management Skill

This skill provides automatic GitHub token management for lobster agents, including
initial token retrieval and automatic refresh for long-running tasks.

## Overview

Lobster agents interact with the lobwife broker to obtain short-lived (1-hour),
repository-scoped GitHub installation tokens. This skill handles:

- Initial token request based on task requirements
- Automatic token refresh before expiry
- Git credential helper integration
- Error handling and retry logic

## Usage in Tasks

When a task requires GitHub access, the agent will:

1. Read `TASK_ID` and `TASK_REPOS` from environment
2. Request credentials from lobwife
3. Configure git to use the token
4. Automatically refresh token every 55 minutes
5. Perform git operations (clone, commit, push, PR)

## Implementation

### Token Request

```python
import os
import requests
from datetime import datetime, timedelta

class GitHubTokenManager:
    def __init__(self):
        self.lobwife_url = os.environ['LOBWIFE_URL']
        self.task_id = os.environ['TASK_ID']
        self.repos = os.environ['TASK_REPOS'].split(',')
        self.token = None
        self.expires_at = None
    
    def get_token(self):
        """Get current token, refresh if needed"""
        if not self.token or self._needs_refresh():
            self._request_token()
        return self.token
    
    def _needs_refresh(self):
        """Check if token needs refresh (5 minutes before expiry)"""
        if not self.expires_at:
            return True
        buffer = timedelta(minutes=5)
        return datetime.utcnow() >= (self.expires_at - buffer)
    
    def _request_token(self):
        """Request new token from lobwife"""
        response = requests.post(
            f"{self.lobwife_url}/credentials",
            json={
                'task_id': self.task_id,
                'repos': self.repos
            }
        )
        response.raise_for_status()
        
        data = response.json()
        self.token = data['token']
        self.expires_at = datetime.fromisoformat(
            data['expires_at'].replace('Z', '+00:00')
        )
        
        print(f"[Token] Obtained token for {len(self.repos)} repos, expires at {self.expires_at}")
    
    def refresh_token(self):
        """Explicitly refresh token for long-running tasks"""
        response = requests.post(
            f"{self.lobwife_url}/credentials/refresh",
            json={'task_id': self.task_id}
        )
        response.raise_for_status()
        
        data = response.json()
        self.token = data['token']
        self.expires_at = datetime.fromisoformat(
            data['expires_at'].replace('Z', '+00:00')
        )
        
        print(f"[Token] Refreshed token, expires at {self.expires_at}")
```

### Git Credential Helper

Create a git credential helper that automatically provides tokens:

```python
# /usr/local/bin/git-credential-lobwife
#!/usr/bin/env python3
import sys
import os
import requests

def main():
    command = sys.argv[1] if len(sys.argv) > 1 else None
    
    if command == 'get':
        # Git is requesting credentials
        task_id = os.environ.get('TASK_ID')
        lobwife_url = os.environ.get('LOBWIFE_URL')
        
        if not task_id or not lobwife_url:
            sys.exit(1)
        
        # Request fresh token
        response = requests.post(
            f"{lobwife_url}/credentials/refresh",
            json={'task_id': task_id}
        )
        
        if response.status_code != 200:
            sys.exit(1)
        
        token = response.json()['token']
        
        # Output credentials in git format
        print("protocol=https")
        print("host=github.com")
        print("username=x-access-token")
        print(f"password={token}")
    
    elif command in ['store', 'erase']:
        # We don't persist credentials
        pass

if __name__ == '__main__':
    main()
```

### Task Execution Pattern

```python
# lobster_agent.py
import os
import subprocess
from github_token_manager import GitHubTokenManager

def main():
    # Initialize token manager
    token_mgr = GitHubTokenManager()
    
    # Get initial token
    token = token_mgr.get_token()
    
    # Configure git
    setup_git_config(token)
    
    # Parse task
    task_id = os.environ['TASK_ID']
    repos = os.environ['TASK_REPOS'].split(',')
    instructions = os.environ['TASK_INSTRUCTIONS']
    
    print(f"[Lobster] Starting task {task_id}")
    print(f"[Lobster] Repositories: {repos}")
    print(f"[Lobster] Instructions: {instructions}")
    
    # Execute task with Claude Code
    # Claude Code will use git credentials automatically
    for repo in repos:
        process_repository(repo, instructions, token_mgr)
    
    print(f"[Lobster] Task {task_id} complete")

def setup_git_config(token):
    """Configure git with credentials"""
    # Set credential helper
    subprocess.run(['git', 'config', '--global', 'credential.helper', 
                   'lobwife'], check=True)
    
    # Set user info
    subprocess.run(['git', 'config', '--global', 'user.name', 
                   'Claude Lobster'], check=True)
    subprocess.run(['git', 'config', '--global', 'user.email', 
                   'lobster@claude-cluster.local'], check=True)

def process_repository(repo_url, instructions, token_mgr):
    """Process a single repository"""
    # Ensure fresh token before git operations
    token = token_mgr.get_token()
    
    # Clone repo
    print(f"[Lobster] Cloning {repo_url}")
    subprocess.run(['git', 'clone', f"https://github.com/{repo_url}"], 
                  check=True)
    
    repo_name = repo_url.split('/')[-1]
    os.chdir(repo_name)
    
    # Create branch
    branch_name = f"lobster-task-{os.environ['TASK_ID']}"
    subprocess.run(['git', 'checkout', '-b', branch_name], check=True)
    
    # Execute Claude Code task
    # (Claude Code performs the actual development work)
    execute_claude_task(instructions)
    
    # Refresh token if needed (task may have taken >55 minutes)
    token = token_mgr.get_token()
    
    # Commit changes
    subprocess.run(['git', 'add', '.'], check=True)
    subprocess.run(['git', 'commit', '-m', 
                   f'Lobster task: {instructions[:50]}'], check=True)
    
    # Push branch
    subprocess.run(['git', 'push', 'origin', branch_name], check=True)
    
    # Create PR (using GitHub CLI or API)
    create_pull_request(repo_url, branch_name, instructions, token)

def execute_claude_task(instructions):
    """Execute development task using Claude Code"""
    # This is where Claude Code performs the actual work
    # based on the instructions
    pass

def create_pull_request(repo, branch, instructions, token):
    """Create PR using GitHub API"""
    import requests
    
    org, repo_name = repo.split('/')
    
    response = requests.post(
        f"https://api.github.com/repos/{org}/{repo_name}/pulls",
        headers={
            'Authorization': f'token {token}',
            'Accept': 'application/vnd.github.v3+json'
        },
        json={
            'title': f'Lobster Task: {instructions[:50]}',
            'body': f'Automated changes by Claude Lobster\n\nTask: {instructions}',
            'head': branch,
            'base': 'main'
        }
    )
    
    if response.status_code == 201:
        pr_url = response.json()['html_url']
        print(f"[Lobster] Created PR: {pr_url}")
    else:
        print(f"[Lobster] Failed to create PR: {response.text}")

if __name__ == '__main__':
    main()
```

## Token Refresh for Long Tasks

For tasks exceeding 55 minutes, implement automatic refresh:

```python
import threading
import time

class TokenRefreshDaemon:
    """Background thread that refreshes token every 55 minutes"""
    
    def __init__(self, token_manager):
        self.token_manager = token_manager
        self.running = False
        self.thread = None
    
    def start(self):
        """Start refresh daemon"""
        self.running = True
        self.thread = threading.Thread(target=self._refresh_loop, daemon=True)
        self.thread.start()
        print("[Token Daemon] Started automatic refresh")
    
    def stop(self):
        """Stop refresh daemon"""
        self.running = False
        if self.thread:
            self.thread.join()
    
    def _refresh_loop(self):
        """Refresh token every 55 minutes"""
        while self.running:
            time.sleep(55 * 60)  # 55 minutes
            if self.running:
                try:
                    self.token_manager.refresh_token()
                except Exception as e:
                    print(f"[Token Daemon] Refresh failed: {e}")

# Usage in agent
token_mgr = GitHubTokenManager()
refresh_daemon = TokenRefreshDaemon(token_mgr)
refresh_daemon.start()

# Perform long-running task
execute_task()

refresh_daemon.stop()
```

## Error Handling

```python
def get_token_with_retry(token_manager, max_retries=3):
    """Get token with exponential backoff retry"""
    import time
    
    for attempt in range(max_retries):
        try:
            return token_manager.get_token()
        except requests.exceptions.RequestException as e:
            if attempt == max_retries - 1:
                raise
            
            wait_time = 2 ** attempt  # Exponential backoff
            print(f"[Token] Request failed, retrying in {wait_time}s: {e}")
            time.sleep(wait_time)
```

## Security Notes

- Tokens are never logged or persisted to disk
- Git credential helper requests fresh tokens per operation
- Token expiry is strictly enforced (1 hour max)
- Each task gets tokens scoped only to required repos
- Audit trail maintained in lobwife

## Troubleshooting

**Token request fails with 403:**
- Check GitHub App installation on target repos
- Verify lobwife has correct installation ID
- Ensure repos are specified in format: "org/repo-name"

**Git operations fail with authentication error:**
- Check git credential helper is configured
- Verify LOBWIFE_URL environment variable
- Test token manually: `curl -H "Authorization: token $TOKEN" https://api.github.com/user`

**Token expired during long operation:**
- Ensure refresh daemon is running
- Check network connectivity to lobwife
- Review lobwife logs for refresh failures
```

---

## 4. Complete Workflow Example

### Task Submission

```python
# task_dispatcher.py
import subprocess
import json

def submit_task(repos, instructions):
    """Submit a task to the lobster cluster"""
    
    task_id = generate_task_id()
    
    # Create K8s Job for lobster
    job_manifest = f"""
apiVersion: batch/v1
kind: Job
metadata:
  name: lobster-{task_id}
  namespace: lobster-cluster
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: lobster
        image: your-registry/lobster:latest
        env:
        - name: TASK_ID
          value: "{task_id}"
        - name: TASK_REPOS
          value: "{','.join(repos)}"
        - name: TASK_INSTRUCTIONS
          value: "{instructions}"
        - name: LOBWIFE_URL
          value: "http://lobwife.lobster-cluster.svc.cluster.local:8080"
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: anthropic-credentials
              key: api-key
"""
    
    # Apply manifest
    process = subprocess.run(
        ['kubectl', 'apply', '-f', '-'],
        input=job_manifest.encode(),
        capture_output=True
    )
    
    if process.returncode == 0:
        print(f"Task {task_id} submitted successfully")
        return task_id
    else:
        print(f"Error submitting task: {process.stderr.decode()}")
        return None

# Example usage
submit_task(
    repos=['myorg/frontend', 'myorg/shared-components'],
    instructions='Add a button with a label that counts button clicks'
)
```

### End-to-End Flow

```
1. User submits task via API/UI
   ↓
2. Task dispatcher creates K8s Job for lobster
   ↓
3. Lobster pod starts
   ↓
4. Lobster requests token from lobwife
   - POST /credentials with task_id and repos
   ↓
5. Lobwife generates scoped token
   - Validates task
   - Calls GitHub API for installation token
   - Returns token scoped to specific repos
   ↓
6. Lobster configures git with token
   ↓
7. Lobster clones repos, creates branch
   ↓
8. Claude Code executes development work
   ↓
9. (If >55 mins) Token auto-refreshes
   - POST /credentials/refresh
   - Lobwife generates new token
   ↓
10. Lobster commits, pushes, creates PR
   ↓
11. Task complete, pod terminates
```

---

## 5. Monitoring and Observability

### Lobwife Metrics

```python
# Add to lobwife/server.py
from prometheus_client import Counter, Histogram, generate_latest

# Metrics
token_requests = Counter('lobwife_token_requests_total', 
                        'Total token requests', ['status'])
token_refresh = Counter('lobwife_token_refreshes_total',
                       'Total token refreshes', ['status'])
request_duration = Histogram('lobwife_request_duration_seconds',
                            'Request duration')

@app.route('/metrics')
def metrics():
    return generate_latest()
```

### Audit Query Examples

```bash
# View all tokens issued for a task
curl http://lobwife:8080/audit?task_id=task-abc-123

# Recent audit log
curl http://lobwife:8080/audit | jq '.[-10:]'

# Count refreshes per task
curl http://lobwife:8080/audit | jq '
  [.[] | select(.action == "token_refreshed")] 
  | group_by(.task_id) 
  | map({task: .[0].task_id, refreshes: length})
'
```

---

## 6. Security Considerations

### Token Lifecycle
- Maximum lifetime: 1 hour (GitHub enforced)
- Automatic expiry (no manual revocation needed for short tasks)
- Refresh creates entirely new token (old one invalid)

### Access Control
- Tokens scoped to exact repos needed per task
- No "list all repos" capability
- Cannot access repos outside task scope (403 error)

### Secrets Management
- GitHub App private key stored in K8s secrets
- Never exposed to lobster pods
- Only lobwife has access
- Rotate via setup wizard re-run

### Network Policies
```yaml
# Recommended network policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: lobster-network-policy
spec:
  podSelector:
    matchLabels:
      app: lobster
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: lobwife
    ports:
    - protocol: TCP
      port: 8080
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 53  # DNS
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
    ports:
    - protocol: TCP
      port: 443  # HTTPS to GitHub
```

---

## 7. Deployment Checklist

- [ ] Run setup wizard to create GitHub App
- [ ] Install GitHub App to required repositories
- [ ] Store credentials in K8s secret `github-app-credentials`
- [ ] Deploy lobwife service
- [ ] Verify lobwife health: `curl http://lobwife:8080/health`
- [ ] Create lobster skills ConfigMap
- [ ] Test single lobster job
- [ ] Verify token request flow
- [ ] Test token refresh for >1hr task
- [ ] Configure monitoring and alerts
- [ ] Set up audit log retention
- [ ] Document organization-specific repo access policies

---

## 8. Common Issues

**Issue: Token request returns 404**
- Cause: Installation ID not set or incorrect
- Fix: Verify `GITHUB_INSTALLATION_ID` in lobwife deployment

**Issue: Git clone fails with "Repository not found"**
- Cause: Token not scoped to that repo
- Fix: Verify repo listed in task TASK_REPOS

**Issue: PR creation fails**
- Cause: GitHub App lacks `pull_requests:write` permission
- Fix: Update app permissions in GitHub settings, regenerate token

**Issue: Long task fails after 1 hour**
- Cause: Token expired, refresh not working
- Fix: Verify refresh daemon running, check lobwife connectivity

---

## Appendix: GitHub App Permissions Reference

Recommended permissions for Claude Code agents:

```json
{
  "contents": "write",           // Clone, commit, push
  "pull_requests": "write",      // Create/update PRs
  "metadata": "read",            // Read repo metadata
  "issues": "write",             // Optional: Create issues
  "workflows": "write"           // Optional: Modify GitHub Actions
}
```

Minimal permissions for read-only tasks:

```json
{
  "contents": "read",
  "metadata": "read"
}
```
