from invoke import task


@task
def deploy(ctx):
    ctx.run(
        "gcloud functions deploy process_crash_reports --runtime python37 --project decoded-cove-239422 --trigger-http --allow-unauthenticated"
    )
