"""Custom MCP tools for lobboss (discord_post, spawn_lobster, lobster_status)."""

import logging
import os
import re
from datetime import datetime, timezone
from typing import Any

from claude_agent_sdk import create_sdk_mcp_server, tool

logger = logging.getLogger("lobboss.mcp_tools")

# Reference to the Discord bot, injected at startup
_bot = None

# k8s client, lazy-initialized
_k8s_batch = None
_k8s_core = None

NAMESPACE = "lobmob"
LOBSTER_IMAGE = os.environ.get(
    "LOBSTER_IMAGE", "ghcr.io/minsley/lobmob-lobster:latest"
)
VAULT_REPO = os.environ.get("VAULT_REPO", "minsley/lobmob-vault-dev")

# Workflow-specific container images (override default lobster image)
WORKFLOW_IMAGES = {
    "android": os.environ.get("LOBSTER_ANDROID_IMAGE", LOBSTER_IMAGE),
    "unity": os.environ.get("LOBSTER_UNITY_IMAGE", LOBSTER_IMAGE),
}

VALID_LOBSTER_TYPES = ("swe", "qa", "research", "image-gen")


def set_bot(bot: Any) -> None:
    """Inject the Discord bot instance for discord_post to use."""
    global _bot
    _bot = bot


def _get_k8s_clients():
    """Lazy-init kubernetes clients. Uses in-cluster config when running in a pod."""
    global _k8s_batch, _k8s_core
    if _k8s_batch is None:
        from kubernetes import client, config

        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()
        _k8s_batch = client.BatchV1Api()
        _k8s_core = client.CoreV1Api()
    return _k8s_batch, _k8s_core


def _sanitize_k8s_name(name: str) -> str:
    """Sanitize a string for use in k8s resource names (lowercase, alphanumeric + hyphens, max 63 chars)."""
    name = name.lower()
    name = re.sub(r"[^a-z0-9-]", "-", name)
    name = re.sub(r"-+", "-", name).strip("-")
    return name[:63]


@tool("discord_post", "Post a message to a Discord channel or thread", {
    "channel_id": str,
    "content": str,
})
async def discord_post(args: dict[str, Any]) -> dict[str, Any]:
    """Post a message to a Discord channel or thread."""
    if _bot is None:
        return {"content": [{"type": "text", "text": "Error: Discord bot not initialized"}]}

    channel_id = int(args["channel_id"])
    content = args["content"]

    channel = _bot.get_channel(channel_id)
    if channel is None:
        return {"content": [{"type": "text", "text": f"Error: Channel {channel_id} not found"}]}

    msg = await channel.send(content)
    logger.info("Posted to channel %s: message %s", channel_id, msg.id)
    return {"content": [{"type": "text", "text": f"Posted message {msg.id} to channel {channel_id}"}]}


@tool("spawn_lobster", "Spawn a lobster worker agent for a task", {
    "task_id": str,
    "lobster_type": str,
    "workflow": str,
})
async def spawn_lobster(args: dict[str, Any]) -> dict[str, Any]:
    """Spawn a lobster worker by creating a k8s Job."""
    from kubernetes import client

    task_id = args["task_id"]
    lobster_type = args["lobster_type"]
    workflow = args.get("workflow", "default")

    if lobster_type == "system":
        return {"content": [{"type": "text", "text": "System tasks are processed autonomously by lobsigliere every 30s. Do not spawn lobsters for type=system."}]}

    if lobster_type not in VALID_LOBSTER_TYPES:
        return {"content": [{"type": "text", "text": f"Error: Invalid lobster_type '{lobster_type}'. Must be one of: {', '.join(VALID_LOBSTER_TYPES)}"}]}

    # Resolve container image: workflow-specific override or default
    image = WORKFLOW_IMAGES.get(workflow, LOBSTER_IMAGE)

    batch_api, _ = _get_k8s_clients()
    job_name = _sanitize_k8s_name(f"lobster-{lobster_type}-{task_id}")

    labels = {
        "app.kubernetes.io/name": "lobster",
        "app.kubernetes.io/part-of": "lobmob",
        "lobmob.io/task-id": _sanitize_k8s_name(task_id),
        "lobmob.io/lobster-type": lobster_type,
        "lobmob.io/workflow": workflow,
    }

    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(
            name=job_name,
            namespace=NAMESPACE,
            labels=labels,
        ),
        spec=client.V1JobSpec(
            backoff_limit=0,
            active_deadline_seconds=7200,
            ttl_seconds_after_finished=3600,
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(labels=labels),
                spec=client.V1PodSpec(
                    restart_policy="Never",
                    node_selector={"lobmob.io/role": "lobster"},
                    service_account_name="lobster",
                    init_containers=[
                        client.V1Container(
                            name="vault-clone",
                            image="alpine/git:latest",
                            command=["/bin/sh", "-c"],
                            args=[
                                f'git clone "https://x-access-token:$(GH_TOKEN)@github.com/{VAULT_REPO}.git" /opt/vault'
                            ],
                            env=[
                                client.V1EnvVar(
                                    name="GH_TOKEN",
                                    value_from=client.V1EnvVarSource(
                                        secret_key_ref=client.V1SecretKeySelector(
                                            name="lobmob-secrets",
                                            key="GH_APP_PRIVATE_KEY",
                                        )
                                    ),
                                ),
                            ],
                            volume_mounts=[
                                client.V1VolumeMount(name="vault", mount_path="/opt/vault"),
                            ],
                        ),
                        # Native sidecar (k8s 1.29+): restartPolicy=Always makes this
                        # run alongside the main container and auto-terminate when it exits.
                        client.V1Container(
                            name="web",
                            image=image,
                            restart_policy="Always",
                            command=["node", "/app/scripts/lobmob-web-lobster.js"],
                            ports=[client.V1ContainerPort(container_port=8080, name="http")],
                            env=[
                                client.V1EnvVar(name="TASK_ID", value=task_id),
                                client.V1EnvVar(name="LOBSTER_TYPE", value=lobster_type),
                                client.V1EnvVar(
                                    name="MY_POD_NAME",
                                    value_from=client.V1EnvVarSource(
                                        field_ref=client.V1ObjectFieldSelector(
                                            field_path="metadata.name",
                                        )
                                    ),
                                ),
                            ],
                            resources=client.V1ResourceRequirements(
                                requests={"memory": "32Mi", "cpu": "10m"},
                                limits={"memory": "64Mi", "cpu": "50m"},
                            ),
                        ),
                    ],
                    containers=[
                        client.V1Container(
                            name="lobster",
                            image=image,
                            image_pull_policy="Always",
                            args=[
                                "--task", task_id,
                                "--type", lobster_type,
                                "--vault-path", "/opt/vault",
                            ],
                            env=[
                                client.V1EnvVar(
                                    name="ANTHROPIC_API_KEY",
                                    value_from=client.V1EnvVarSource(
                                        secret_key_ref=client.V1SecretKeySelector(
                                            name="lobmob-secrets", key="ANTHROPIC_API_KEY"
                                        )
                                    ),
                                ),
                                client.V1EnvVar(
                                    name="GH_TOKEN",
                                    value_from=client.V1EnvVarSource(
                                        secret_key_ref=client.V1SecretKeySelector(
                                            name="lobmob-secrets", key="GH_APP_PRIVATE_KEY"
                                        )
                                    ),
                                ),
                                client.V1EnvVar(
                                    name="LOBMOB_ENV",
                                    value_from=client.V1EnvVarSource(
                                        config_map_key_ref=client.V1ConfigMapKeySelector(
                                            name="lobboss-config", key="LOBMOB_ENV"
                                        )
                                    ),
                                ),
                                client.V1EnvVar(name="TASK_ID", value=task_id),
                                client.V1EnvVar(name="LOBSTER_TYPE", value=lobster_type),
                                client.V1EnvVar(name="LOBSTER_WORKFLOW", value=workflow),
                            ] + (
                                # Pass Gemini API key to image-gen lobsters
                                [client.V1EnvVar(
                                    name="GEMINI_API_KEY",
                                    value_from=client.V1EnvVarSource(
                                        secret_key_ref=client.V1SecretKeySelector(
                                            name="lobmob-secrets", key="GEMINI_API_KEY",
                                            optional=True,
                                        )
                                    ),
                                )] if lobster_type == "image-gen" else []
                            ),
                            resources=client.V1ResourceRequirements(
                                requests={"memory": "1Gi", "cpu": "500m"},
                                limits={"memory": "3Gi", "cpu": "1500m"},
                            ),
                            volume_mounts=[
                                client.V1VolumeMount(name="vault", mount_path="/opt/vault"),
                                client.V1VolumeMount(name="workspace", mount_path="/workspace"),
                            ],
                        ),
                    ],
                    volumes=[
                        client.V1Volume(name="vault", empty_dir=client.V1EmptyDirVolumeSource()),
                        client.V1Volume(name="workspace", empty_dir=client.V1EmptyDirVolumeSource()),
                    ],
                ),
            ),
        ),
    )

    try:
        result = batch_api.create_namespaced_job(namespace=NAMESPACE, body=job)
        logger.info("Created k8s Job %s for task %s (type=%s, workflow=%s)",
                     job_name, task_id, lobster_type, workflow)
        return {"content": [{"type": "text", "text": f"Spawned job: {result.metadata.name} (type={lobster_type}, workflow={workflow})"}]}
    except Exception as e:
        logger.error("Failed to create k8s Job %s: %s", job_name, e)
        return {"content": [{"type": "text", "text": f"Error creating job {job_name}: {e}"}]}


@tool("lobster_status", "Get status of lobster workers", {
    "task_id": str,
})
async def lobster_status(args: dict[str, Any]) -> dict[str, Any]:
    """Get lobster worker status by querying k8s Jobs and Pods."""
    task_id = args.get("task_id", "")
    batch_api, core_api = _get_k8s_clients()

    try:
        label_selector = "app.kubernetes.io/name=lobster"
        if task_id:
            label_selector += f",lobmob.io/task-id={_sanitize_k8s_name(task_id)}"

        jobs = batch_api.list_namespaced_job(namespace=NAMESPACE, label_selector=label_selector)

        if not jobs.items:
            return {"content": [{"type": "text", "text": "No active lobster jobs found."}]}

        lines = []
        for job in jobs.items:
            name = job.metadata.name
            task = job.metadata.labels.get("lobmob.io/task-id", "?")
            ltype = job.metadata.labels.get("lobmob.io/lobster-type", "?")

            # Determine status
            if job.status.succeeded and job.status.succeeded > 0:
                status = "succeeded"
            elif job.status.failed and job.status.failed > 0:
                status = "failed"
            elif job.status.active and job.status.active > 0:
                status = "running"
            else:
                status = "pending"

            # Calculate age
            age = ""
            if job.metadata.creation_timestamp:
                delta = datetime.now(timezone.utc) - job.metadata.creation_timestamp
                minutes = int(delta.total_seconds() / 60)
                if minutes < 60:
                    age = f"{minutes}m"
                else:
                    age = f"{minutes // 60}h{minutes % 60}m"

            lines.append(f"- {name} | task={task} type={ltype} status={status} age={age}")

            # Get last few log lines for running/failed jobs
            if status in ("running", "failed"):
                try:
                    pod_selector = f"job-name={name}"
                    pods = core_api.list_namespaced_pod(
                        namespace=NAMESPACE, label_selector=pod_selector
                    )
                    if pods.items:
                        pod = pods.items[0]
                        try:
                            logs = core_api.read_namespaced_pod_log(
                                name=pod.metadata.name,
                                namespace=NAMESPACE,
                                container="lobster",
                                tail_lines=5,
                            )
                            if logs:
                                lines.append(f"  logs: {logs.strip()[-200:]}")
                        except Exception:
                            pass
                except Exception:
                    pass

        return {"content": [{"type": "text", "text": "\n".join(lines)}]}
    except Exception as e:
        logger.error("Failed to query lobster status: %s", e)
        return {"content": [{"type": "text", "text": f"Error querying status: {e}"}]}


# MCP server instance — wire into ClaudeAgentOptions.mcp_servers
lobmob_mcp = create_sdk_mcp_server(
    name="lobmob",
    version="1.0.0",
    tools=[discord_post, spawn_lobster, lobster_status],
)
