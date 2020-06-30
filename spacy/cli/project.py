from typing import List, Dict, Any, Optional, Sequence
import typer
import srsly
from pathlib import Path
from wasabi import msg
import subprocess
import os
import re
import shutil
import sys
import requests
import tqdm

from ._app import app, Arg, Opt, COMMAND, NAME
from .. import about
from ..schemas import ProjectConfigSchema, validate
from ..util import ensure_path, run_command, make_tempdir, working_dir
from ..util import get_hash, get_checksum, split_command


CONFIG_FILE = "project.yml"
DVC_CONFIG = "dvc.yaml"
DVC_DIR = ".dvc"
DIRS = [
    "assets",
    "metas",
    "configs",
    "packages",
    "metrics",
    "scripts",
    "notebooks",
    "training",
    "corpus",
]
CACHES = [
    Path.home() / ".torch",
    Path.home() / ".caches" / "torch",
    os.environ.get("TORCH_HOME"),
    Path.home() / ".keras",
]
DVC_CONFIG_COMMENT = """# This file is auto-generated by spaCy based on your project.yml. Do not edit
# it directly and edit the project.yml instead and re-run the project."""
CLI_HELP = f"""Command-line interface for spaCy projects and working with project
templates. You'd typically start by cloning a project template to a local
directory and fetching its assets like datasets etc. See the project's
{CONFIG_FILE} for the available commands. Under the hood, spaCy uses DVC (Data
Version Control) to manage input and output files and to ensure steps are only
re-run if their inputs change.
"""

project_cli = typer.Typer(help=CLI_HELP, no_args_is_help=True)


@project_cli.callback(invoke_without_command=True)
def callback(ctx: typer.Context):
    """This runs before every project command and ensures DVC is installed."""
    ensure_dvc()


################
# CLI COMMANDS #
################


@project_cli.command("clone")
def project_clone_cli(
    # fmt: off
    name: str = Arg(..., help="The name of the template to fetch"),
    dest: Path = Arg(Path.cwd(), help="Where to download and work. Defaults to current working directory.", exists=False),
    repo: str = Opt(about.__projects__, "--repo", "-r", help="The repository to look in."),
    git: bool = Opt(False, "--git", "-G", help="Initialize project as a Git repo"),
    no_init: bool = Opt(False, "--no-init", "-NI", help="Don't initialize the project with DVC"),
    # fmt: on
):
    """Clone a project template from a repository. Calls into "git" and will
    only download the files from the given subdirectory. The GitHub repo
    defaults to the official spaCy template repo, but can be customized
    (including using a private repo). Setting the --git flag will also
    initialize the project directory as a Git repo. If the project is intended
    to be a Git repo, it should be initialized with Git first, before
    initializing DVC (Data Version Control). This allows DVC to integrate with
    Git.
    """
    if dest == Path.cwd():
        dest = dest / name
    project_clone(name, dest, repo=repo, git=git, no_init=no_init)


@project_cli.command("init")
def project_init_cli(
    # fmt: off
    path: Path = Arg(Path.cwd(), help="Path to cloned project. Defaults to current working directory.", exists=True, file_okay=False),
    git: bool = Opt(False, "--git", "-G", help="Initialize project as a Git repo"),
    force: bool = Opt(False, "--force", "-F", help="Force initiziation"),
    # fmt: on
):
    """Initialize a project directory with DVC and optionally Git. This should
    typically be taken care of automatically when you run the "project clone"
    command, but you can also run it separately. If the project is intended to
    be a Git repo, it should be initialized with Git first, before initializing
    DVC. This allows DVC to integrate with Git.
    """
    project_init(path, git=git, force=force, silent=True)


@project_cli.command("assets")
def project_assets_cli(
    # fmt: off
    project_dir: Path = Arg(Path.cwd(), help="Path to cloned project. Defaults to current working directory.", exists=True, file_okay=False),
    # fmt: on
):
    """Use DVC (Data Version Control) to fetch project assets. Assets are
    defined in the "assets" section of the project config. If possible, DVC
    will try to track the files so you can pull changes from upstream. It will
    also try and store the checksum so the assets are versioned. If the file
    can't be tracked or checked, it will be downloaded without DVC. If a checksum
    is provided in the project config, the file is only downloaded if no local
    file with the same checksum exists.
    """
    project_assets(project_dir)


@project_cli.command(
    "run-all",
    context_settings={"allow_extra_args": True, "ignore_unknown_options": True},
)
def project_run_all_cli(
    # fmt: off
    ctx: typer.Context,
    project_dir: Path = Arg(Path.cwd(), help="Location of project directory. Defaults to current working directory.", exists=True, file_okay=False),
    show_help: bool = Opt(False, "--help", help="Show help message and available subcommands")
    # fmt: on
):
    """Run all commands defined in the project. This command will use DVC and
    the defined outputs and dependencies in the project config to determine
    which steps need to be re-run and where to start. This means you're only
    re-generating data if the inputs have changed.

    This command calls into "dvc repro" and all additional arguments are passed
    to the "dvc repro" command: https://dvc.org/doc/command-reference/repro
    """
    if show_help:
        print_run_help(project_dir)
    else:
        project_run_all(project_dir, *ctx.args)


@project_cli.command(
    "run", context_settings={"allow_extra_args": True, "ignore_unknown_options": True},
)
def project_run_cli(
    # fmt: off
    ctx: typer.Context,
    subcommand: str = Arg(None, help="Name of command defined in project config"),
    project_dir: Path = Arg(Path.cwd(), help="Location of project directory. Defaults to current working directory.", exists=True, file_okay=False),
    show_help: bool = Opt(False, "--help", help="Show help message and available subcommands")
    # fmt: on
):
    """Run a named script defined in the project config. If the command is
    part of the default pipeline defined in the "run" section, DVC is used to
    determine whether the step should re-run if its inputs have changed, or
    whether everything is up to date. If the script is not part of the default
    pipeline, it will be called separately without DVC.

    If DVC is used, the command calls into "dvc repro" and all additional
    arguments are passed to the "dvc repro" command:
    https://dvc.org/doc/command-reference/repro
    """
    if show_help or not subcommand:
        print_run_help(project_dir, subcommand)
    else:
        project_run(project_dir, subcommand, *ctx.args)


@project_cli.command("exec", hidden=True)
def project_exec_cli(
    # fmt: off
    subcommand: str = Arg(..., help="Name of command defined in project config"),
    project_dir: Path = Arg(Path.cwd(), help="Location of project directory. Defaults to current working directory.", exists=True, file_okay=False),
    # fmt: on
):
    """Execute a command defined in the project config. This CLI command is
    only called internally in auto-generated DVC pipelines, as a shortcut for
    multi-step commands in the project config. You typically shouldn't have to
    call it yourself. To run a command, call "run" or "run-all".
    """
    project_exec(project_dir, subcommand)


@project_cli.command("update-dvc")
def project_update_dvc_cli(
    # fmt: off
    project_dir: Path = Arg(Path.cwd(), help="Location of project directory. Defaults to current working directory.", exists=True, file_okay=False),
    verbose: bool = Opt(False, "--verbose", "-V", help="Print more info"),
    force: bool = Opt(False, "--force", "-F", help="Force update DVC config"),
    # fmt: on
):
    """Update the auto-generated DVC config file. Uses the steps defined in the
    "run" section of the project config. This typically happens automatically
    when running a command, but can also be triggered manually if needed.
    """
    config = load_project_config(project_dir)
    updated = update_dvc_config(project_dir, config, verbose=verbose, force=force)
    if updated:
        msg.good(f"Updated DVC config from {CONFIG_FILE}")
    else:
        msg.info(f"No changes found in {CONFIG_FILE}, no update needed")


app.add_typer(project_cli, name="project")


#################
# CLI FUNCTIONS #
#################


def project_clone(
    name: str,
    dest: Path,
    *,
    repo: str = about.__projects__,
    git: bool = False,
    no_init: bool = False,
) -> None:
    """Clone a project template from a repository.

    name (str): Name of subdirectory to clone.
    dest (Path): Destination path of cloned project.
    repo (str): URL of Git repo containing project templates.
    git (bool): Initialize project as Git repo. Should be set to True if project
        is intended as a repo, since it will allow DVC to integrate with Git.
    no_init (bool): Don't initialize DVC and Git automatically. If True, the
        "init" command or "git init" and "dvc init" need to be run manually.
    """
    dest = ensure_path(dest)
    check_clone(name, dest, repo)
    project_dir = dest.resolve()
    # We're using Git and sparse checkout to only clone the files we need
    with make_tempdir() as tmp_dir:
        cmd = f"git clone {repo} {tmp_dir} --no-checkout --depth 1 --config core.sparseCheckout=true"
        try:
            run_command(cmd)
        except SystemExit:
            err = f"Could not clone the repo '{repo}' into the temp dir '{tmp_dir}'"
            msg.fail(err)
        with (tmp_dir / ".git" / "info" / "sparse-checkout").open("w") as f:
            f.write(name)
        run_command(["git", "-C", str(tmp_dir), "fetch"])
        run_command(["git", "-C", str(tmp_dir), "checkout"])
        shutil.move(str(tmp_dir / Path(name).name), str(project_dir))
    msg.good(f"Cloned project '{name}' from {repo} into {project_dir}")
    for sub_dir in DIRS:
        dir_path = project_dir / sub_dir
        if not dir_path.exists():
            dir_path.mkdir(parents=True)
    if not no_init:
        project_init(project_dir, git=git, force=True, silent=True)
    msg.good(f"Your project is now ready!", dest)
    print(f"To fetch the assets, run:\n{COMMAND} project assets {dest}")


def project_init(
    project_dir: Path,
    *,
    git: bool = False,
    force: bool = False,
    silent: bool = False,
    analytics: bool = False,
):
    """Initialize a project as a DVC and (optionally) as a Git repo.

    project_dir (Path): Path to project directory.
    git (bool): Also call "git init" to initialize directory as a Git repo.
    silent (bool): Don't print any output (via DVC).
    analytics (bool): Opt-in to DVC analytics (defaults to False).
    """
    with working_dir(project_dir) as cwd:
        if git:
            run_command(["git", "init"])
        init_cmd = ["dvc", "init"]
        if silent:
            init_cmd.append("--quiet")
        if not git:
            init_cmd.append("--no-scm")
        if force:
            init_cmd.append("--force")
        run_command(init_cmd)
        # We don't want to have analytics on by default – our users should
        # opt-in explicitly. If they want it, they can always enable it.
        if not analytics:
            run_command(["dvc", "config", "core.analytics", "false"])
        # Remove unused and confusing plot templates from .dvc directory
        # TODO: maybe we shouldn't do this, but it's otherwise super confusing
        # once you commit your changes via Git and it creates a bunch of files
        # that have no purpose
        plots_dir = cwd / DVC_DIR / "plots"
        if plots_dir.exists():
            shutil.rmtree(str(plots_dir))
        config = load_project_config(cwd)
        setup_check_dvc(cwd, config)


def project_assets(project_dir: Path) -> None:
    """Fetch assets for a project using DVC if possible.

    project_dir (Path): Path to project directory.
    """
    project_path = ensure_path(project_dir)
    config = load_project_config(project_path)
    setup_check_dvc(project_path, config)
    assets = config.get("assets", {})
    if not assets:
        msg.warn(f"No assets specified in {CONFIG_FILE}", exits=0)
    msg.info(f"Fetching {len(assets)} asset(s)")
    variables = config.get("variables", {})
    fetched_assets = []
    for asset in assets:
        url = asset["url"].format(**variables)
        dest = asset["dest"].format(**variables)
        fetched_path = fetch_asset(project_path, url, dest, asset.get("checksum"))
        if fetched_path:
            fetched_assets.append(str(fetched_path))
    if fetched_assets:
        with working_dir(project_path):
            run_command(["dvc", "add", *fetched_assets, "--external"])


def fetch_asset(
    project_path: Path, url: str, dest: Path, checksum: Optional[str] = None
) -> Optional[Path]:
    """Fetch an asset from a given URL or path. Will try to import the file
    using DVC's import-url if possible (fully tracked and versioned) and falls
    back to get-url (versioned) and a non-DVC download if necessary. If a
    checksum is provided and a local file exists, it's only re-downloaded if the
    checksum doesn't match.

    project_path (Path): Path to project directory.
    url (str): URL or path to asset.
    checksum (Optional[str]): Optional expected checksum of local file.
    RETURNS (Optional[Path]): The path to the fetched asset or None if fetching
        the asset failed.
    """
    url = convert_asset_url(url)
    dest_path = (project_path / dest).resolve()
    if dest_path.exists() and checksum:
        # If there's already a file, check for checksum
        # TODO: add support for caches (dvc import-url with local path)
        if checksum == get_checksum(dest_path):
            msg.good(f"Skipping download with matching checksum: {dest}")
            return dest_path
    with working_dir(project_path):
        try:
            # If these fail, we don't want to output an error or info message.
            # Try with tracking the source first, then just downloading with
            # DVC, then a regular non-DVC download.
            try:
                dvc_cmd = ["dvc", "import-url", url, str(dest_path)]
                print(subprocess.check_output(dvc_cmd, stderr=subprocess.DEVNULL))
            except subprocess.CalledProcessError:
                dvc_cmd = ["dvc", "get-url", url, str(dest_path)]
                print(subprocess.check_output(dvc_cmd, stderr=subprocess.DEVNULL))
        except subprocess.CalledProcessError:
            try:
                download_file(url, dest_path)
            except requests.exceptions.HTTPError as e:
                msg.fail(f"Download failed: {dest}", e)
                return None
    if checksum and checksum != get_checksum(dest_path):
        msg.warn(f"Checksum doesn't match value defined in {CONFIG_FILE}: {dest}")
    msg.good(f"Fetched asset {dest}")
    return dest_path


def project_run_all(project_dir: Path, *dvc_args) -> None:
    """Run all commands defined in the project using DVC.

    project_dir (Path): Path to project directory.
    *dvc_args: Other arguments passed to "dvc repro".
    """
    config = load_project_config(project_dir)
    setup_check_dvc(project_dir, config)
    dvc_cmd = ["dvc", "repro", *dvc_args]
    with working_dir(project_dir):
        run_command(dvc_cmd)


def print_run_help(project_dir: Path, subcommand: Optional[str] = None) -> None:
    """Simulate a CLI help prompt using the info available in the project config.

    project_dir (Path): The project directory.
    subcommand (Optional[str]): The subcommand or None. If a subcommand is
        provided, the subcommand help is shown. Otherwise, the top-level help
        and a list of available commands is printed.
    """
    config = load_project_config(project_dir)
    setup_check_dvc(project_dir, config)
    config_commands = config.get("commands", [])
    commands = {cmd["name"]: cmd for cmd in config_commands}
    if subcommand:
        validate_subcommand(commands.keys(), subcommand)
        print(f"Usage: {COMMAND} project run {subcommand} {project_dir}")
        help_text = commands[subcommand].get("help")
        if help_text:
            msg.text(f"\n{help_text}\n")
    else:
        print(f"\nAvailable commands in {CONFIG_FILE}")
        print(f"Usage: {COMMAND} project run [COMMAND] {project_dir}")
        msg.table([(cmd["name"], cmd.get("help", "")) for cmd in config_commands])
        msg.text("Run all commands defined in the 'run' block of the project config:")
        print(f"{COMMAND} project run-all {project_dir}")


def project_run(project_dir: Path, subcommand: str, *dvc_args) -> None:
    """Run a named script defined in the project config. If the script is part
    of the default pipeline (defined in the "run" section), DVC is used to
    execute the command, so it can determine whether to rerun it. It then
    calls into "exec" to execute it.

    project_dir (Path): Path to project directory.
    subcommand (str): Name of command to run.
    *dvc_args: Other arguments passed to "dvc repro".
    """
    config = load_project_config(project_dir)
    setup_check_dvc(project_dir, config)
    config_commands = config.get("commands", [])
    variables = config.get("variables", {})
    commands = {cmd["name"]: cmd for cmd in config_commands}
    validate_subcommand(commands.keys(), subcommand)
    if subcommand in config.get("run", []):
        # This is one of the pipeline commands tracked in DVC
        dvc_cmd = ["dvc", "repro", subcommand, *dvc_args]
        with working_dir(project_dir):
            run_command(dvc_cmd)
    else:
        cmd = commands[subcommand]
        # Deps in non-DVC commands aren't tracked, but if they're defined,
        # make sure they exist before running the command
        for dep in cmd.get("deps", []):
            if not (project_dir / dep).exists():
                err = f"Missing dependency specified by command '{subcommand}': {dep}"
                msg.fail(err, exits=1)
        with working_dir(project_dir):
            run_commands(cmd["script"], variables)


def project_exec(project_dir: Path, subcommand: str):
    """Execute a command defined in the project config.

    project_dir (Path): Path to project directory.
    subcommand (str): Name of command to run.
    """
    config = load_project_config(project_dir)
    config_commands = config.get("commands", [])
    variables = config.get("variables", {})
    commands = {cmd["name"]: cmd for cmd in config_commands}
    with working_dir(project_dir):
        run_commands(commands[subcommand]["script"], variables)


###########
# HELPERS #
###########


def load_project_config(path: Path) -> Dict[str, Any]:
    """Load the project config file from a directory and validate it.

    path (Path): The path to the project directory.
    RETURNS (Dict[str, Any]): The loaded project config.
    """
    config_path = path / CONFIG_FILE
    if not config_path.exists():
        msg.fail("Can't find project config", config_path, exits=1)
    invalid_err = f"Invalid project config in {CONFIG_FILE}"
    try:
        config = srsly.read_yaml(config_path)
    except ValueError as e:
        msg.fail(invalid_err, e, exits=1)
    errors = validate(ProjectConfigSchema, config)
    if errors:
        msg.fail(invalid_err, "\n".join(errors), exits=1)
    return config


def update_dvc_config(
    path: Path,
    config: Dict[str, Any],
    verbose: bool = False,
    silent: bool = False,
    force: bool = False,
) -> bool:
    """Re-run the DVC commands in dry mode and update dvc.yaml file in the
    project directory. The file is auto-generated based on the config. The
    first line of the auto-generated file specifies the hash of the config
    dict, so if any of the config values change, the DVC config is regenerated.

    path (Path): The path to the project directory.
    config (Dict[str, Any]): The loaded project config.
    verbose (bool): Whether to print additional info (via DVC).
    silent (bool): Don't output anything (via DVC).
    force (bool): Force update, even if hashes match.
    RETURNS (bool): Whether the DVC config file was updated.
    """
    config_hash = get_hash(config)
    path = path.resolve()
    dvc_config_path = path / DVC_CONFIG
    if dvc_config_path.exists():
        # Check if the file was generated using the current config, if not, redo
        with dvc_config_path.open("r", encoding="utf8") as f:
            ref_hash = f.readline().strip().replace("# ", "")
        if ref_hash == config_hash and not force:
            return False  # Nothing has changed in project config, don't need to update
        dvc_config_path.unlink()
    variables = config.get("variables", {})
    commands = []
    # We only want to include commands that are part of the main list of "run"
    # commands in project.yml and should be run in sequence
    config_commands = {cmd["name"]: cmd for cmd in config.get("commands", [])}
    for name in config.get("run", []):
        validate_subcommand(config_commands.keys(), name)
        command = config_commands[name]
        deps = command.get("deps", [])
        outputs = command.get("outputs", [])
        outputs_no_cache = command.get("outputs_no_cache", [])
        if not deps and not outputs and not outputs_no_cache:
            continue
        # Default to "." as the project path since dvc.yaml is auto-generated
        # and we don't want arbitrary paths in there
        project_cmd = ["python", "-m", NAME, "project", ".", "exec", name]
        deps_cmd = [c for cl in [["-d", p] for p in deps] for c in cl]
        outputs_cmd = [c for cl in [["-o", p] for p in outputs] for c in cl]
        outputs_nc_cmd = [c for cl in [["-O", p] for p in outputs_no_cache] for c in cl]
        dvc_cmd = ["dvc", "run", "-n", name, "-w", str(path), "--no-exec"]
        if verbose:
            dvc_cmd.append("--verbose")
        if silent:
            dvc_cmd.append("--quiet")
        full_cmd = [*dvc_cmd, *deps_cmd, *outputs_cmd, *outputs_nc_cmd, *project_cmd]
        commands.append(" ".join(full_cmd))
    with working_dir(path):
        run_commands(commands, variables, silent=True)
    with dvc_config_path.open("r+", encoding="utf8") as f:
        content = f.read()
        f.seek(0, 0)
        f.write(f"# {config_hash}\n{DVC_CONFIG_COMMENT}\n{content}")
    return True


def ensure_dvc() -> None:
    """Ensure that the "dvc" command is available and show an error if not."""
    try:
        subprocess.run(["dvc", "--version"], stdout=subprocess.DEVNULL)
    except Exception:
        msg.fail(
            "spaCy projects require DVC (Data Version Control) and the 'dvc' command",
            "You can install the Python package from pip (pip install dvc) or "
            "conda (conda install -c conda-forge dvc). For more details, see the "
            "documentation: https://dvc.org/doc/install",
            exits=1,
        )


def setup_check_dvc(project_dir: Path, config: Dict[str, Any]) -> None:
    """Check that the project is set up correctly with DVC and update its
    config if needed. Will raise an error if the project is not an initialized
    DVC project.

    project_dir (Path): The path to the project directory.
    config (Dict[str, Any]): The loaded project config.
    """
    if not project_dir.exists():
        msg.fail(f"Can't find project directory: {project_dir}")
    if not (project_dir / ".dvc").exists():
        msg.fail(
            "Project not initialized as a DVC project.",
            f"Make sure that the project template was cloned correctly. To "
            f"initialize the project directory manually, you can run: "
            f"{COMMAND} project init {project_dir}",
            exits=1,
        )
    with msg.loading("Updating DVC config..."):
        updated = update_dvc_config(project_dir, config, silent=True)
    if updated:
        msg.good(f"Updated DVC config from changed {CONFIG_FILE}")


def run_commands(
    commands: List[str] = tuple(), variables: Dict[str, str] = {}, silent: bool = False
) -> None:
    """Run a sequence of commands in a subprocess, in order.

    commands (List[str]): The string commands.
    variables (Dict[str, str]): Dictionary of variable names, mapped to their
        values. Will be used to substitute format string variables in the
        commands.
    silent (bool): Don't print the commands.
    """
    for command in commands:
        # Substitute variables, e.g. "./{NAME}.json"
        command = command.format(**variables)
        command = split_command(command)
        # Not sure if this is needed or a good idea. Motivation: users may often
        # use commands in their config that reference "python" and we want to
        # make sure that it's always executing the same Python that spaCy is
        # executed with and the pip in the same env, not some other Python/pip.
        # Also ensures cross-compatibility if user 1 writes "python3" (because
        # that's how it's set up on their system), and user 2 without the
        # shortcut tries to re-run the command.
        if len(command) and command[0] in ("python", "python3"):
            command[0] = sys.executable
        elif len(command) and command[0] in ("pip", "pip3"):
            command = [sys.executable, "-m", "pip", *command[1:]]
        if not silent:
            print(f"Running command: {' '.join(command)}")
        run_command(command)


def convert_asset_url(url: str) -> str:
    """Check and convert the asset URL if needed.

    url (str): The asset URL.
    RETURNS (str): The converted URL.
    """
    # If the asset URL is a regular GitHub URL it's likely a mistake
    if re.match("(http(s?)):\/\/github.com", url):
        converted = url.replace("github.com", "raw.githubusercontent.com")
        converted = re.sub(r"/(tree|blob)/", "/", converted)
        msg.warn(
            "Downloading from a regular GitHub URL. This will only download "
            "the source of the page, not the actual file. Converting the URL "
            "to a raw URL.",
            converted,
        )
        return converted
    return url


def check_clone(name: str, dest: Path, repo: str) -> None:
    """Check and validate that the destination path can be used to clone. Will
    check that Git is available and that the destination path is suitable.

    name (str): Name of the directory to clone from the repo.
    dest (Path): Local destination of cloned directory.
    repo (str): URL of the repo to clone from.
    """
    try:
        subprocess.run(["git", "--version"], stdout=subprocess.DEVNULL)
    except Exception:
        msg.fail(
            f"Cloning spaCy project templates requires Git and the 'git' command. ",
            f"To clone a project without Git, copy the files from the '{name}' "
            f"directory in the {repo} to {dest} manually and then run:",
            f"{COMMAND} project init {dest}",
            exits=1,
        )
    if not dest:
        msg.fail(f"Not a valid directory to clone project: {dest}", exits=1)
    if dest.exists():
        # Directory already exists (not allowed, clone needs to create it)
        msg.fail(f"Can't clone project, directory already exists: {dest}", exits=1)
    if not dest.parent.exists():
        # We're not creating parents, parent dir should exist
        msg.fail(
            f"Can't clone project, parent directory doesn't exist: {dest.parent}",
            exits=1,
        )


def validate_subcommand(commands: Sequence[str], subcommand: str) -> None:
    """Check that a subcommand is valid and defined. Raises an error otherwise.

    commands (Sequence[str]): The available commands.
    subcommand (str): The subcommand.
    """
    if subcommand not in commands:
        msg.fail(
            f"Can't find command '{subcommand}' in {CONFIG_FILE}. "
            f"Available commands: {', '.join(commands)}",
            exits=1,
        )


def download_file(url: str, dest: Path, chunk_size: int = 1024) -> None:
    """Download a file using requests.

    url (str): The URL of the file.
    dest (Path): The destination path.
    chunk_size (int): The size of chunks to read/write.
    """
    response = requests.get(url, stream=True)
    response.raise_for_status()
    total = int(response.headers.get("content-length", 0))
    progress_settings = {
        "total": total,
        "unit": "iB",
        "unit_scale": True,
        "unit_divisor": chunk_size,
        "leave": False,
    }
    with dest.open("wb") as f, tqdm.tqdm(**progress_settings) as bar:
        for data in response.iter_content(chunk_size=chunk_size):
            size = f.write(data)
            bar.update(size)
