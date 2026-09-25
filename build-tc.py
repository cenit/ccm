#!/usr/bin/env python3
"""
build-tc.py
Build TwinCAT Project using Beckhoff COM automation in Python.

Created By: Stefano Sinigardi
Created Date: October 17, 2024
Last Modified Date: March 31, 2026

Copyright (c) Stefano Sinigardi - MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Dependencies:
    comtypes (pip install comtypes)
"""

import argparse
import os
import re
import sys
import time

BUILD_TC_VERSION = "2.0.0"

OUTPUT_WINDOW_GUID = "{34E76E81-EE4A-11D0-AE2E-00A0C90FFFC3}"

DTE_PROG_IDS = [
    "TcXaeShell.DTE.17.0",
    "VisualStudio.DTE.17.0",
    "TcXaeShell.DTE.15.0",
    "VisualStudio.DTE.15.0",
]


class Logger:
    """Tee output to both stdout and a log file."""

    def __init__(self, log_path):
        self.log_path = log_path
        self.log_file = open(log_path, "w", encoding="utf-8")

    def write(self, msg):
        print(msg)
        self.log_file.write(msg + "\n")
        self.log_file.flush()

    def close(self):
        self.log_file.close()


def create_dte(com_client):
    """Try to create a DTE COM object using multiple ProgIDs in fallback order."""
    for prog_id in DTE_PROG_IDS:
        try:
            dte = com_client.CreateObject(prog_id)
            return dte, prog_id
        except Exception:
            continue
    return None, None


def extract_build_output(dte):
    """Extract build output from the Output Window's Build pane.

    Uses index-based window iteration because GUID-based Item() lookup
    does not work reliably with all COM client libraries.
    """
    try:
        output_window = None
        windows = dte.Windows
        for i in range(1, windows.Count + 1):
            try:
                w = windows.Item(i)
                if w.ObjectKind == OUTPUT_WINDOW_GUID:
                    output_window = w
                    break
            except Exception:
                continue

        if output_window is None:
            return None

        try:
            output_window.Activate()
        except Exception:
            pass
        time.sleep(1)

        output_obj = output_window.Object
        panes = output_obj.OutputWindowPanes

        for p in range(1, panes.Count + 1):
            try:
                pane = panes.Item(p)
                pane_name = getattr(pane, "Name", "")
                td = pane.TextDocument
                text = td.StartPoint.CreateEditPoint().GetText(td.EndPoint)
                if text and ("error" in text.lower() or "Build complete" in text):
                    return text
            except Exception:
                continue

        return None
    except Exception:
        return None


def parse_build_output(raw_text):
    """Parse build output text and extract error/warning lines and summary counts."""
    error_lines = []
    parsed_errors = 0
    parsed_warnings = 0

    for line in raw_text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        lower = stripped.lower()
        if any(kw in lower for kw in ["error", "warning", "cannot find", "build complete", "failed"]):
            error_lines.append(stripped)

    m = re.search(r"Build complete -- (\d+) errors?,\s*(\d+) warnings?", raw_text)
    if m:
        parsed_errors = int(m.group(1))
        parsed_warnings = int(m.group(2))

    return error_lines, parsed_errors, parsed_warnings


def build(prj_dir, prj_name, platform_to_build, log):
    """Main build routine. Returns exit code (0=success, 1=failure)."""

    try:
        import comtypes.client as comtypes_client
    except ImportError:
        log.write("ERROR: comtypes module is required. Install with: pip install comtypes")
        return 1

    # Resolve project path
    prj_path = os.path.join(prj_dir, prj_name)
    prj_path = os.path.abspath(prj_path)

    if not os.path.isfile(prj_path):
        log.write(f"ERROR: Solution file not found: {prj_path}")
        return 1

    log.write(f"build-tc version {BUILD_TC_VERSION}")
    log.write(f"Python {sys.version}")
    log.write(f"Project: {prj_path}")
    log.write(f"Platform: {platform_to_build}")
    log.write("")

    # Create DTE COM object
    log.write("Creating COM object...")
    dte, prog_id = create_dte(comtypes_client)
    if dte is None:
        log.write("ERROR: Could not create any TcXaeShell or VisualStudio DTE COM object.")
        log.write("Tried: " + ", ".join(DTE_PROG_IDS))
        log.write("Make sure TwinCAT XAE is installed.")
        return 1
    log.write(f"Successfully created {prog_id}")

    total_errors = 0

    try:
        # Open solution
        sln = dte.Solution
        log.write(f"Opening {prj_path}...")
        sln.Open(prj_path)
        log.write("Loading...")
        time.sleep(15)

        # Iterate configurations
        configs = sln.SolutionBuild.SolutionConfigurations
        for ci in range(1, configs.Count + 1):
            config = configs.Item(ci)
            if config is None:
                continue

            try:
                contexts = config.SolutionContexts
            except Exception:
                continue

            platform_names = set()
            for j in range(1, contexts.Count + 1):
                try:
                    ctx = contexts.Item(j)
                    platform_names.add(ctx.PlatformName)
                except Exception:
                    continue

            for platform_name in platform_names:
                if platform_name != platform_to_build:
                    log.write(f"Discarding configuration: {platform_name} | {config.Name}")
                    continue

                log.write(f"Activating configuration:  {platform_name} | {config.Name}")
                config.Activate()
                time.sleep(2)

                log.write(f"Cleaning configuration:    {platform_name} | {config.Name}")
                sln.SolutionBuild.Clean(True)
                time.sleep(2)

                log.write(f"Building configuration:    {platform_name} | {config.Name}")
                sln.SolutionBuild.Build(True)
                time.sleep(3)

                failed_projects = sln.SolutionBuild.LastBuildInfo
                log.write(f"Failed projects:           {failed_projects}")

                # Extract detailed errors from Output Window
                raw_output = extract_build_output(dte)
                if raw_output:
                    error_lines, parsed_errors, parsed_warnings = parse_build_output(raw_output)
                    for line in error_lines:
                        log.write(f"    >> {line}")
                    if parsed_errors > 0 or parsed_warnings > 0:
                        log.write(f"Parsed from output: {parsed_errors} errors, {parsed_warnings} warnings")
                    if parsed_errors > 0:
                        total_errors += parsed_errors
                    elif failed_projects > 0:
                        total_errors += failed_projects
                elif failed_projects > 0:
                    log.write(f"Build FAILED ({failed_projects} project(s) failed, no details available)")
                    total_errors += failed_projects

                log.write(f"Built configuration:       {platform_name} | {config.Name}")

        # Close solution
        log.write(f"Closing {prj_path}...")
        sln.Close()
        time.sleep(3)

    except Exception as e:
        log.write(f"ERROR during build: {e}")
        total_errors += 1
    finally:
        try:
            dte.Quit()
            log.write("Closing Visual Studio...")
        except Exception:
            pass

    log.write("")
    log.write(f"Total errors across all configurations: {total_errors}")

    return 1 if total_errors > 0 else 0


def main():
    parser = argparse.ArgumentParser(
        description="Build TwinCAT Project using Beckhoff COM automation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"build-tc version {BUILD_TC_VERSION}",
    )
    parser.add_argument(
        "--prj-dir",
        default=".",
        help='Directory containing the solution file (default: ".")',
    )
    parser.add_argument(
        "--prj-name",
        default="Template_project.sln",
        help='Solution file name (default: "Template_project.sln")',
    )
    parser.add_argument(
        "--platform",
        default="TwinCAT RT (x64)",
        help='Target platform (default: "TwinCAT RT (x64)")',
    )
    parser.add_argument(
        "--disable-interactive",
        action="store_true",
        help="Disable interactive prompts (for CI/CD)",
    )

    args = parser.parse_args()

    # Determine log path (next to solution file)
    log_dir = os.path.abspath(args.prj_dir)
    log_path = os.path.join(log_dir, "build-tc.log")

    log = Logger(log_path)
    log.write(f"Log file: {log_path}")

    try:
        exit_code = build(args.prj_dir, args.prj_name, args.platform, log)
    except Exception as e:
        log.write(f"FATAL: {e}")
        exit_code = 1
    finally:
        log.close()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
