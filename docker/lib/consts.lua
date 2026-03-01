local consts = {}

consts.status = {
    PENDING  = "pending",
    CLAIMED  = "claimed",
    RUNNING  = "running",
    STOPPED  = "stopped",
    FAILED   = "failed",
    REMOVED  = "removed",
}

consts.stream = {
    STDOUT = "stdout",
    STDERR = "stderr",
}

consts.topic = {
    CONTAINER_NEW    = "container.new",
    CONTAINER_LOG    = "container.log",
    CONTAINER_STATUS = "container.status",
    SUBSCRIBE        = "container.subscribe",
    UNSUBSCRIBE      = "container.unsubscribe",
    STDIN            = "stdin",

    IMAGE_BUILD_NEW       = "image.build.new",
    IMAGE_BUILD_LOG       = "image.build.log",
    IMAGE_BUILD_STATUS    = "image.build.status",
    IMAGE_BUILD_SUBSCRIBE   = "image.build.subscribe",
    IMAGE_BUILD_UNSUBSCRIBE = "image.build.unsubscribe",
}

consts.image_status = {
    AVAILABLE = "available",
    BUILDING  = "building",
    PULLING   = "pulling",
    FAILED    = "failed",
}

consts.build_status = {
    PENDING   = "pending",
    BUILDING  = "building",
    COMPLETED = "completed",
    FAILED    = "failed",
}

consts.restart_policy = {
    NONE       = "none",
    ON_FAILURE = "on-failure",
    ALWAYS     = "always",
}

consts.registry = {
    ROOT          = "docker.root",
    WORKER        = "docker.worker",
    MONITOR       = "docker.monitor",
    IMAGE_BUILDER = "docker.image_builder",
}

consts.defaults = {
    MONITOR_INTERVAL   = "10s",
    FALLBACK_INTERVAL  = "30s",
    LOG_TTL            = 3600,
    MAX_RESTARTS       = 3,
    WORKER_COUNT       = 2,
}

return consts
