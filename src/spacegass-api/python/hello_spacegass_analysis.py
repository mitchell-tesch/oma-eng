"""
hello_spacegass_analysis.py — run a linear static analysis via the
SPACE GASS 14.5+ REST API and print the resulting reactions.

Purpose: demonstrate the full solve-and-read cycle end-to-end from
Omarchy — the workflow that used to require COM automation or `.$PR`
file scraping is now four idempotent HTTP calls.

Modelled on the vendor run-analysis sample —
https://github.com/SpaceGass/space-gass-api/blob/main/sdks/python/examples/run_analysis/run_analysis.py

The script:
  1. Opens the built-in `Portal Frame.SG` sample (or a project path
     you pass on the command line).
  2. Starts a linear-static run using current job settings.
  3. Polls the run status until Completed / Failed / Cancelled.
  4. On completion, queries node reactions and prints a summary.
  5. Closes the job.

Prereqs (in the guest):
    - SPACE GASS 14.5 or later, opened at least once
    - `py -m pip install --user -r requirements.txt`
    - SpaceGassApi.exe running (default http://localhost:34560)

Run:
    py hello_spacegass_analysis.py
    py hello_spacegass_analysis.py C:\\path\\to\\MyProject.sg
"""

from __future__ import annotations

import asyncio
import sys

from space_gass_api import SpaceGassApiClient
import space_gass_api.models as models


BASE_URL = "http://localhost:34560"
POLL_INTERVAL_S = 0.5


async def open_job(client, project_path: str | None) -> None:
    if project_path is None:
        print("Opening built-in sample 'Portal Frame.SG'...")
        await client.job.open_sample.post(
            models.OpenSampleRequest(file_name="Portal Frame.SG"),
        )
    else:
        print(f"Opening project: {project_path}")
        await client.job.open.post(
            models.OpenJobRequest(file_path=project_path),
        )


async def run_linear_static(client):
    """Kick off a linear static analysis and return the initial run info."""
    print("Starting linear static analysis...")
    run = await client.job.analysis.static.run_linear.post(
        models.StaticSettingsUpdate(),  # empty body = keep current settings
    )
    if run is None:
        raise RuntimeError("No response from run-linear endpoint.")
    print(f"  Run ID: {run.run_id}  Status: {run.status}")
    return run


async def wait_for_completion(client, run_id) -> models.AnalysisRunStatus:
    terminal = {
        models.AnalysisRunStatus.Completed,
        models.AnalysisRunStatus.Failed,
        models.AnalysisRunStatus.Cancelled,
    }
    while True:
        await asyncio.sleep(POLL_INTERVAL_S)
        status = await client.job.analysis.runs.by_run_id(str(run_id)).get()
        if status is None:
            raise RuntimeError("Run status query returned None.")
        if status.progress is not None:
            p = status.progress
            print(
                f"\r  Step {p.current_step}/{p.total_steps}"
                f" {p.iteration_percentage}%  {p.status_text or ''}",
                end="", flush=True,
            )
        if status.status in terminal:
            print()  # clear the trailing progress line
            return status


async def print_reactions(client) -> None:
    query = await client.job.query.analysis.static.node_reactions.get()
    reactions = query.results if query else None
    if not reactions:
        print("  (no reactions returned — check the model has restraints)")
        return
    print(f"  {len(reactions)} reaction result(s):")
    for r in reactions[:10]:
        print(
            f"    Node {r.node} LC {r.load_case}: "
            f"Fx={r.fx:+.2f} Fy={r.fy:+.2f} Fz={r.fz:+.2f}"
        )
    if len(reactions) > 10:
        print(f"    ... and {len(reactions) - 10} more")


async def main() -> int:
    project_path = sys.argv[1] if len(sys.argv) > 1 else None
    client = SpaceGassApiClient.create_client(BASE_URL)

    try:
        await open_job(client, project_path)
        run = await run_linear_static(client)
        final = await wait_for_completion(client, run.run_id)

        print(f"Analysis {final.status}. Elapsed: {final.elapsed_time}")
        if final.warnings:
            print(f"  Warnings ({len(final.warnings)}):")
            for w in final.warnings:
                print(f"    {w}")
        if final.error_message:
            print(f"  Error: {final.error_message}", file=sys.stderr)

        if final.status == models.AnalysisRunStatus.Completed:
            print()
            print("Querying node reactions...")
            await print_reactions(client)

        print("Hello from SPACE GASS on Omarchy.")

    except models.ErrorResponse as err:
        print(f"API error {err.status}: {err.title}", file=sys.stderr)
        if err.detail:
            print(f"  {err.detail}", file=sys.stderr)
        return 1
    except Exception as ex:
        print(f"Error: {ex}", file=sys.stderr)
        return 1
    finally:
        print("Closing project...")
        await client.job.close.post()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
