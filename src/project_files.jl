# The persistent server copy and the agent's worker workspace are distinct.
function project_worker_folder(worker, p::Project)
    root = replace(worker.projects_root, '\\' => '/')
    isempty(root) && throw(AppError("configure a projects directory for worker $(worker.name) first"))
    return rstrip(root, '/') * "/BonitoCommunity/" * p.id
end

function prepare_project_worker!(app::CommunityApp, worker, p::Project)
    source = project_folder(projects_dir(app), p)
    isdir(source) || throw(AppError("the persistent project folder is missing on the server: $source"))
    destination = project_worker_folder(worker, p)
    try
        BonitoAgents.sync_dir_to_worker!(app.ctx.server, worker.worker_id, source, destination; quick_check=false)
    catch e
        throw(AppError("could not prepare project $(p.id) on $(worker.name) at $destination: $(sprint(showerror, e))"))
    end
    return destination
end

function collect_project_files!(app::CommunityApp, p::Project, chat)
    destination = project_folder(projects_dir(app), p)
    # Existing installations may already share this exact folder.
    chat.worker_path == destination && return nothing
    # Pull into staging because the server's transport normally mirrors and
    # deletes absent files. Community keeps its original material persistently.
    mktempdir() do stage
        try
            BonitoAgents.sync_dir_from_worker!(app.ctx.server, chat.worker_id, chat.worker_path, stage; quick_check=false)
        catch e
            throw(AppError("could not collect project files from worker $(chat.worker_id): $(sprint(showerror, e))"))
        end
        for (root, dirs, files) in walkdir(stage)
            target = joinpath(destination, relpath(root, stage))
            mkpath(target)
            for dir in dirs
                mkpath(joinpath(target, dir))
            end
            for file in files
                output = joinpath(target, file)
                isdir(output) && throw(AppError("worker file conflicts with a server directory: $output"))
                cp(joinpath(root, file), output; force=true)
            end
        end
    end
    notify(app.state)
    return nothing
end
