#!/usr/bin/env python3

import glob
import shutil
import subprocess
from urllib.request import Request

import pdfkit

from bibtexparser.bwriter import BibTexWriter
from weasyprint import HTML

from citationkeys.bib import *
from citationkeys.tags import *
from citationkeys.urlhandlers import *
from citationkeys.print import *


class AliasedGroup(click.Group):
    def get_command(self, ctx, cmd_name):
        rv = click.Group.get_command(self, ctx, cmd_name)
        if rv is not None:
            return rv

        matches = [x for x in self.list_commands(ctx)
                   if x.startswith(cmd_name)]

        if not matches:
            return None
        elif len(matches) == 1:
            return click.Group.get_command(self, ctx, matches[0])

        ctx.fail('Too many matches: %s' % ', '.join(sorted(matches)))


def prompt_for_bibtex(ctx, initial_bibtex):
    bibtex = initial_bibtex

    # Continue asking the user for bibtex until they enter valid bibtex
    while True:
        bibtex = click.edit(bibtex, ctx.obj['TextEditor'])
        if bibtex == None or len(bibtex.strip()) == 0:
            print_error(
                "You did not input any BibTex in the text editor. Exiting.")
            sys.exit(1)

        bibtex = bibtex.encode('utf-8')

        try:
            # , None, ctx.obj['DefaultCk'], ctx.obj['verbosity'])
            bibent = bibtex_to_bibent(bibtex)

            # If the parsing succeeded, break out of the loop and return
            break
        except:
            print_error("Could not parse BibTeX! See stack trace below:")
            print()
            traceback.print_exc()
            print()

            if input("Continue editing to fix the errors? [y/N]: ").lower() != "y":
                sys.exit(1)

    return bibtex, bibent


# @click.group(invoke_without_command=True)
@click.group(cls=AliasedGroup)
@click.option(
    '-c', '--config-file',
    default=os.path.join(appdirs.user_config_dir('ck'), 'ck.config'),
    help='Path to ck config file.'
)
@click.option(
    '-v', '--verbose',
    count=True,
    help='Pass multiple times for extra detail.'
)
@click.pass_context
def ck(ctx, config_file, verbose):
    if ctx.invoked_subcommand is None:
        click.echo('I was invoked without subcommand, listing bibliography...')
        notimplemented()
        click.echo('Call with --help for usage.')

    # click.echo("I am about to invoke '%s' subcommand" % ctx.invoked_subcommand)

    if verbose > 0:
        click.echo("Verbosity level: " + str(verbose))
        click.echo("Reading CK config file at " + config_file)

    # read configuration
    if not os.path.exists(config_file):
        print_error("CK config file does not exist: " + config_file)
        sys.exit(1)

    if verbose > 1:
        click.echo(file_to_string(config_file).strip())

    config = configparser.ConfigParser()
    with open(config_file, 'r') as f:
        config.read_file(f)

    if verbose > 2:
        click.echo("Configuration sections: " + str(config.sections()))

    # set a context with various config params that we pass around to the subcommands
    try:
        ctx.ensure_object(dict)
        ctx.obj['verbosity'] = verbose
        ctx.obj['BibDir'] = config['default']['BibDir']
        ctx.obj['TagDir'] = config['default']['TagDir']
        ctx.obj['DefaultCk'] = config['default']['DefaultCk']
        ctx.obj['TextEditor'] = config['default']['TextEditor']
        ctx.obj['MarkdownEditor'] = config['default']['MarkdownEditor']
        ctx.obj['TagAfterCkAddConflict'] = config['default']['TagAfterCkAddConflict'].lower(
        ) == "true"
        ctx.obj['tags'] = find_tagged_pdfs(ctx.obj['TagDir'], verbose)

        # Maps domain of website to function that handles downloading paper's PDF & BibTeX from it
        #
        # TODO(Alex): Change to regex matching
        # NOTE(Alin): Sure, but for now might be overkill: the only time we need it is for [www.]sciencedirect.com
        #
        # TODO(Alex): Incorporate Zotero translators (see https://www.zotero.org/support/translators)
        ctx.obj['handlers'] = {
            "link.springer.com": springerlink_handler,
            "arxiv.org": arxiv_handler,
            "rd.springer.com": springerlink_handler,
            "eprint.iacr.org": iacreprint_handler,
            "dl.acm.org": dlacm_handler,
            "epubs.siam.org": epubssiam_handler,
            "ieeexplore.ieee.org": ieeexplore_handler,
            "www.sciencedirect.com": sciencedirect_handler,
            "sciencedirect.com": sciencedirect_handler,
        }
    except:
        print_error("Config file '" + config_file +
                    "' is in bad shape. Please edit manually!")
        raise

    # set command to open PDFs with
    if sys.platform.startswith('linux'):
        ctx.obj['OpenCmd'] = 'xdg-open'
    elif sys.platform == 'darwin':
        ctx.obj['OpenCmd'] = 'open -a Highlights'
        # ctx.obj['OpenCmd'] = 'open'
    else:
        print_error(sys.platform + " is not supported.")
        sys.exit(1)

    if verbose > 0:
        click.echo()

    # always do a sanity check before invoking the actual subcommand
    # TODO(Alin): figure out how to call this *after* (not before) the subcommand is invoked, so the user can actually see its output
    # ck_check(ctx.obj['BibDir'], ctx.obj['TagDir'], verbose)


@ck.command('check')
@click.pass_context
def ck_check_cmd(ctx):
    """Checks the BibDir and TagDir for integrity."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    ck_check(ck_bib_dir, ck_tag_dir, verbosity)


def ck_check(ck_bib_dir, ck_tag_dir, verbosity):
    # find PDFs without bib files (and viceversa)
    missing = {}
    missing['.pdf'] = []
    missing['.bib'] = []
    counterpart_ext = {}
    counterpart_ext['.pdf'] = '.bib'
    counterpart_ext['.bib'] = '.pdf'

    extensions = missing.keys()
    for ck in list_cks(ck_bib_dir, False):
        for ext in extensions:
            filepath = os.path.join(ck_bib_dir, ck + ext)

            if verbosity > 1:
                print("Checking", filepath)

            counterpart = os.path.join(ck_bib_dir, ck + counterpart_ext[ext])

            if not os.path.exists(counterpart):
                missing[counterpart_ext[ext]].append(ck)

    for ext in ['.pdf', '.bib']:
        if len(missing[ext]) > 0:
            print("Papers with missing " + ext + " files:")
            print("------------------------------")

        missing[ext].sort()
        for f in missing[ext]:
            print(" - " + f)

        if len(missing[ext]) > 0:
            print()

    # make sure all .pdf extensions are lowercase in TagDir
    for relpath in os.listdir(ck_tag_dir):
        filepath = os.path.join(ck_tag_dir, relpath)
        ck, extOrig = os.path.splitext(relpath)

        ext = extOrig.lower()
        if ext != extOrig:
            print_warning(filepath + " has uppercase " + "." +
                          extOrig + " extension in TagDir")

    # TODO(Alin): make sure symlinks are not broken in TagDir
    # TODO(Alin): make sure all .bib files have the right CK and have ckdateadded


def error_citation_exists(ctx, citation_key):
    click.secho(style_error("Citation key ") + style_ck(citation_key) +
                style_error(" already exists. Pick a different one."), err=True)

    askToTagConflict = ctx.obj['TagAfterCkAddConflict']

    if askToTagConflict:
        # Could be useful to ask the user to tag the conflicting paper?
        print()
        if click.confirm("Would you like to tag the existing paper?", default=True):
            print()
            # prompt user to tag paper
            ctx.invoke(ck_tag_cmd, citation_key=citation_key)


@ck.command('addbib')
@click.argument('url', required=False, type=click.STRING)
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_addbib_cmd(ctx, url, citation_key):
    """Adds the paper's .bib file to the library, without a PDF file,
       unless one already exists. Uses the specified citation key, if given and not already used.
       Otherwise, uses the DefaultCk policy in the configuration file."""

    verbosity = ctx.obj['verbosity']
    handlers = ctx.obj['handlers']
    default_ck = ctx.obj['DefaultCk']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    # If no URL was provided, just let the user type in the BibTeX in the text editor.
    if url == None:
        bibtex, _ = prompt_for_bibtex(ctx, "")
        citation_key, bibent = bibtex_to_bibent_with_ck(
            bibtex, None, default_ck, verbosity)
    else:
        # Sets up a HTTP URL opener object, with a random UserAgent to prevent various
        # websites from borking.
        cj = CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cj))
        user_agent = UserAgent().random

        # Download .bib file only
        is_handled, bibtex, _ = handle_url(
            url, handlers, opener, user_agent, verbosity, True, False)

        if not is_handled:
            click.echo(
                "No handler for URL was found. Expecting this URL to be to a .bib file...")
            bibtex = download_bib(opener, user_agent, url, verbosity)

        if verbosity > 0:
            print("Downloaded BibTeX: " + str(bibtex))

        try:
            citation_key, bibent = bibtex_to_bibent_with_ck(
                bibtex, citation_key, default_ck, verbosity)
        except:
            print_error("Could not parse BibTeX! See stack trace below:")
            print()
            traceback.print_exc()
            print()
            sys.exit(1)

    # Write the .bib file
    destbibfile = ck_to_bib(ck_bib_dir, citation_key)
    while os.path.exists(destbibfile):
        prompt = style_warning("Citation key ") + style_ck(citation_key) + \
            style_warning(" already exists, please enter a new one: ")

        citation_key = prompt_for_ck(ctx, prompt)
        destbibfile = ck_to_bib(ck_bib_dir, citation_key)

    click.echo("Will use citation key: ", nl=False)
    click.secho(citation_key, fg="cyan")

    # Sets the 'ckdateadded' field in the .bib file
    bibent['ID'] = citation_key
    bibent_set_dateadded(bibent, None)
    bibent_to_file(destbibfile, bibent)


@ck.command('addpage')
@click.argument('url', required=True, type=click.STRING)
@click.argument('citation_key', required=False, type=click.STRING)
@click.option(
    '-e', '--engine',
    default="weasyprint",
    help="The HTML-to-PDF engine, which can be either 'pdfkit' or 'weasyprint'",
)
@click.option(
    '-n', '--no-tag-prompt',
    is_flag=True,
    default=False,
    help='Does not prompt the user to tag the paper.'
)
@click.pass_context
def ck_addpage_cmd(ctx, url, citation_key, engine, no_tag_prompt):
    """Adds the specified webpage to the library, by converting it to a PDF.
       Uses the specified citation key, if given and not already used.
       Otherwise, uses the DefaultCk policy in the configuration file."""

    verbosity = ctx.obj['verbosity']
    default_ck = ctx.obj['DefaultCk']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    # prompt for .bib with some information like @misc and add URL pre-completed
    original_citation_key = citation_key
    bibent = bibent_from_url(
        citation_key if citation_key is not None else "WillBeDerivedAutomatically", url)

    initial_bibtex = bibent_to_bibtex(bibent)
    _, bibent = prompt_for_bibtex(ctx, initial_bibtex)

    # Use default CK if no CK is was given
    if citation_key is None:
        citation_key = bibent_to_default_ck(bibent, default_ck, verbosity)
        bibent['ID'] = citation_key
    else:
        bibent['ID'] = citation_key

    # make sure derived or user-chose CK is not used
    if ck_exists(ck_bib_dir, citation_key):
        error_citation_exists(ctx, citation_key)
        sys.exit(1)

    # derive .bib and .pdf paths
    destpdffile = ck_to_pdf(ck_bib_dir, citation_key)
    destbibfile = ck_to_bib(ck_bib_dir, citation_key)

    # download HTML as PDF
    if engine == "weasyprint":
        HTML(url).write_pdf(destpdffile)    # defaults to using 'media' print
    elif engine == "pdfkit":
        options = {
            "print-media-type": None  # forces 'media' print
        }
        pdfkit.from_url(url, destpdffile, options)
    else:
        print_error("Unsupported HTML-to-PDF engine: " + engine)
        sys.exit(1)

    # write .bib file
    write_bib_and_prompt_for_tag(
        ctx, destbibfile, bibent, citation_key, no_tag_prompt)


@ck.command('add')
@click.argument('url', required=True, type=click.STRING)
@click.argument('citation_key', required=False, type=click.STRING)
@click.option(
    '-n', '--no-tag-prompt',
    is_flag=True,
    default=False,
    help='Does not prompt the user to tag the paper.'
)
@click.pass_context
def ck_add_cmd(ctx, url, citation_key, no_tag_prompt):
    """Adds the paper to the library (.pdf and .bib file).
       Uses the specified citation key, if given.
       Otherwise, uses the DefaultCk policy in the configuration file."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    handlers = ctx.obj['handlers']
    default_ck = ctx.obj['DefaultCk']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    # Sets up a HTTP URL opener object, with a random UserAgent to prevent various
    # websites from borking.
    cj = CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cj))
    user_agent = UserAgent().random

    # Download PDF (and potentially .bib file too, if the URL is handled)
    is_handled, bibtex, pdf_data = handle_url(
        url, handlers, opener, user_agent, verbosity, True, True)

    if not is_handled:
        click.echo(
            "No handler for URL was found. This is a PDF-only download, so expecting user to give a citation key.")

        # If no citation key is given, fail because we can't check .bib file exists until after
        # user did all the .bib file editing. Thus, it would be unfriendly to tell them their
        # citation key already exists and waste their editing work.
        if not citation_key:
            print_error(
                "Please supply the citation key too, since it cannot be determined from PDF only.")
            sys.exit(1)

        try:
            click.echo("Trying to download as PDF...")
            pdf_data = download_pdf(opener, user_agent, url, verbosity)
        except:
            print_error("Specified URL is probably not a PDF URL.")
            sys.exit(1)

        # If there's no .bib file for the user's citation key, let them edit one manually.
        bibpath_tmp = ck_to_bib(ck_bib_dir, citation_key)
        if not os.path.exists(bibpath_tmp):
            bibent = bibent_from_url(citation_key, url)
            initial_bibtex = bibent_to_bibtex(bibent)
            bibtex, _ = prompt_for_bibtex(ctx, initial_bibtex)
        else:
            # WARNING: Code below expects bibtex to be bytes that it can call .decode() on
            bibtex = file_to_bytes(bibpath_tmp)

    #
    # Invariant: We have the PDF data in pdf_data and the .bib data in bibtex.
    #            If this is a non-handled URL, we also have the citation key for the file.
    #            If it's a handled URL, we can determine the citation key.
    #            Either way, we are ready to check the paper does not exist and, if so, save the files.
    #

    # TODO(Alin): check the URL more carefully (perhaps modify handle_url to tell you which website was handled)
    citation_key, bibent = bibtex_to_bibent_with_ck(
        bibtex, citation_key, default_ck, verbosity)
    bibtex = None  # make sure we never use this again

    # # TODO: Ugh, this should be handled based on the CK policy, no? Also, what if user gives own CK?
    # if "eprint.iacr.org" in url:
    #     citation_key = citation_key + "e"
    #     bibent['ID'] = bibent['ID'] + "e"

    click.echo("Will use citation key: ", nl=False)
    click.secho(citation_key, fg="cyan")

    # Derive PDF and .bib file paths from citation key.
    destpdffile = ck_to_pdf(ck_bib_dir, citation_key)
    destbibfile = ck_to_bib(ck_bib_dir, citation_key)

    # Make sure we've never added this paper's PDF before! Note that its bib file might've been added with `addbib`
    # (Otherwise, user will be surprised when they overwrite their previous papers.)
    if os.path.exists(destpdffile):
        error_citation_exists(ctx, citation_key)
        sys.exit(1)

    # One caveat:
    #  - For handled URLs, if we have a .bib file but no PDF, then something went wrong, so we err on the side of displaying an error to the user
    #  - For non-handled URLs, a .bib file might be there from a previous 'ck bib' or 'ck open' command, and we want to leave it untouched.
    #
    # TODO(Alin): This makes the flow of 'ck add' too complicated to follow.
    # We should simplify it by adding 'ck updatepdf' and 'ck updatebib' as commands used to update the .bib and .pdf files explicitly.
    # Then, 'ck add' should always check that neither a PDF nor a .bib file exists.
    if is_handled and os.path.exists(destbibfile):
        error_citation_exists(ctx, citation_key)
        sys.exit(1)

    # Write the PDF file
    with open(destpdffile, 'wb') as fout:
        fout.write(pdf_data)

    # Will not write the .bib file when this is a non-handled URL and a .bib file exists
    write_bib_and_prompt_for_tag(
        ctx, destbibfile, bibent, citation_key, no_tag_prompt)


def write_bib_and_prompt_for_tag(ctx, destbibfile, bibent, citation_key, no_tag_prompt):
    # Write the .bib file
    if not os.path.exists(destbibfile):
        # First, sets the 'ckdateadded' field in the .bib file
        bibent_set_dateadded(bibent, None)
        bibent_to_file(destbibfile, bibent)

    # Prompt the user to tag the paper
    if not no_tag_prompt:
        # First, open the PDF so the user can read it before asking them for the tags
        ctx.invoke(ck_open_cmd, filename=citation_key)
        ctx.invoke(ck_tag_cmd, citation_key=citation_key, silent=True)


@ck.command('config')
@click.option(
    '-e', '--edit',
    is_flag=True,
    default=False,
    help='Actually opens an editor to edit the file.')
@click.pass_context
def ck_config_cmd(ctx, edit):
    """Lets you edit the config file and prints it at the end."""

    ctx.ensure_object(dict)
    ck_text_editor = ctx.obj['TextEditor']

    config_file = os.path.join(appdirs.user_config_dir('ck'), 'ck.config')

    if not edit:
        print(config_file)
    else:
        os.system(ck_text_editor + " \"" + config_file + "\"")


@ck.command('queue')
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_queue_cmd(ctx, citation_key):
    """Marks this paper as 'to-be-read', removing the 'queue/reading' and/or 'queue/finished' tags"""
    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if citation_key is not None:
        ctx.invoke(ck_tag_cmd, silent=True,
                   citation_key=citation_key, tags="queue/to-read")
        ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key,
                   tags="queue/finished,queue/reading")
    else:
        click.secho("Papers that remain to be read:", bold=True)
        click.echo()

        ctx.invoke(ck_list_cmd, tag_names_or_subdirs=[
                   os.path.join(ck_tag_dir, 'queue/to-read')])


@ck.command('dequeue')
@click.argument('citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_dequeue_cmd(ctx, citation_key):
    """Removes this paper from the to-read list"""
    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    ctx.invoke(ck_untag_cmd, silent=True,
               citation_key=citation_key, tags="queue/to-read")


@ck.command('read')
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_read_cmd(ctx, citation_key):
    """Marks this paper as in the process of 'reading', removing the 'queue/to-read' and/or 'queue/finished' tags"""
    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if citation_key is not None:
        ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key,
                   tags="queue/to-read,queue/finished")
        ctx.invoke(ck_tag_cmd, silent=True,
                   citation_key=citation_key, tags="queue/reading")
        ctx.invoke(ck_open_cmd, filename=citation_key + ".pdf")
    else:
        click.secho("Papers you are currently reading:", bold=True)
        click.echo()

        ctx.invoke(ck_list_cmd, tag_names_or_subdirs=[
                   os.path.join(ck_tag_dir, 'queue/reading')])


@ck.command('finished')
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_finished_cmd(ctx, citation_key):
    """Marks this paper as 'finished reading', removing the 'queue/to-read' and/or 'queue/reading' tags"""
    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if citation_key is not None:
        ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key,
                   tags="queue/to-read,queue/reading")
        ctx.invoke(ck_tag_cmd, silent=True,
                   citation_key=citation_key, tags="queue/finished")
    else:
        click.secho("Papers you have finished reading:", bold=True)
        click.echo()

        ctx.invoke(ck_list_cmd, tag_names_or_subdirs=[
                   os.path.join(ck_tag_dir, 'queue/finished')])


@ck.command('untag')
@click.argument('citation_key', required=False, type=click.STRING)
@click.argument('tags', required=False, nargs=-1, type=click.STRING)
@click.option(
    '-f', '--force',
    is_flag=True,
    default=False,
    help='Do not prompt for confirmation when removing all tags')
@click.option(
    '-s', '--silent',
    is_flag=True,
    default=False,
    help='Does not display error message when paper was not tagged.')
@click.pass_context
def ck_untag_cmd(ctx, force, silent, citation_key, tags):
    """Untags the specified paper."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags = ctx.obj['tags']

    if citation_key is None and len(tags) == 0:
        # If no paper was specified, detects untagged papers and asks the user to tag them.
        untagged_pdfs = find_untagged_pdfs(ck_bib_dir, ck_tag_dir, list_cks(
            ck_bib_dir, False), ck_tags.keys(), verbosity)
        if len(untagged_pdfs) > 0:
            sys.stdout.write("Untagged papers:\n")
            for (filepath, citation_key) in untagged_pdfs:
                # display paper info
                ctx.invoke(ck_info_cmd, citation_key=citation_key)
            click.echo()

            for (filepath, citation_key) in untagged_pdfs:
                # prompt user to tag paper
                ctx.invoke(ck_tag_cmd, citation_key=citation_key)
        else:
            click.echo("No untagged papers.")
    else:
        if len(tags) != 0:
            for tag in tags:
                if untag_paper(ck_tag_dir, citation_key, tag):
                    click.secho("Removed '" + tag + "' tag", fg="green")
                else:
                    # When invoked by ck_{queue/read/finished}_cmd, we want this silenced
                    if not silent:
                        click.secho("Was not tagged with '" + tag +
                                    "' tag to begin with", fg="red", err=True)
        else:
            if force or click.confirm("Are you sure you want to remove ALL tags for " + click.style(citation_key, fg="cyan") + "?"):
                if untag_paper(ck_tag_dir, citation_key):
                    click.secho("Removed all tags!", fg="green")
                else:
                    click.secho("No tags to remove.", fg="red")


@ck.command('info')
@click.argument('citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_info_cmd(ctx, citation_key):
    """Displays info about the specified paper"""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags = ctx.obj['tags']

    include_url = True
    include_venue = True
    print_ck_tuples(cks_to_tuples(
        ck_bib_dir, [citation_key], verbosity), ck_tags, include_url, include_venue)


@ck.command('tags')
@click.argument('matching_tag', required=False, type=click.STRING)
@click.pass_context
def ck_tags_cmd(ctx, matching_tag):
    """Lists all tags in the library. If a <tag> is given as argument, prints matching tags in the library."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags = ctx.obj['tags']

    tags = get_all_tags(ck_tag_dir)
    if matching_tag is None:
        print_tags(tags)
    else:
        matching = []
        for t in tags:
            if matching_tag in t:
                matching.append(t)

        if len(matching) > 0:
            click.echo("Tags matching '" + matching_tag + "': ", nl=False)
            print_tags(matching)
        else:
            click.secho("No tags matching '" + matching_tag +
                        "' in library.", fg='yellow')


@ck.command('tag')
@click.argument('citation_key', required=True, type=click.STRING)
@click.argument('tags', required=False, nargs=-1, type=click.STRING)
@click.option(
    '-s', '--silent',
    is_flag=True,
    default=False,
    help='Does not display error message when paper is already tagged.')
@click.pass_context
def ck_tag_cmd(ctx, silent, citation_key, tags):
    """Tags the specified paper"""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags = ctx.obj['tags']

    # if not silent:
    #    click.echo("Tagging '" + style_ck(citation_key) + "' with " + style_tags(tags) + "...")

    if not silent:
        ctx.invoke(ck_info_cmd, citation_key=citation_key)

    if not ck_exists(ck_bib_dir, citation_key):
        print_error(citation_key + " has no PDF file.")
        sys.exit(1)

    if len(tags) == 0:
        completed = subprocess.run(
            ['which pdfgrep'],
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        tags = get_all_tags(ck_tag_dir)

        if completed.returncode != 0:
            print_warning(
                "Not suggesting any tags because 'pdfgrep' is not installed.")
        elif len(tags) > 0:
            # NOTE(Alin): Tags can be hierarchical, e.g.,, 'accumulators/merkle', so we split them up into separate words by '/'
            words = set()
            for t in tags:
                for w in t.split('/'):
                    words.add(w)
            pattern = ' -e '.join(sorted(words))
            pattern = '-e ' + pattern
            suggested_tags = []

            try:
                pdfpath = ck_to_pdf(ck_bib_dir, citation_key)
                if verbosity > 1:
                    click.echo("Calling pdfgrep " +
                               pattern + " '" + pdfpath + "'")

                matches = subprocess.check_output(
                    "pdfgrep %s %s" % (pattern, pdfpath), shell=True).decode()

                if verbosity > 1:
                    click.echo("pdfgrep returned matches: " + matches)
            except subprocess.CalledProcessError as e:
                print_warning(
                    "Not suggesting any tags because 'pdfgrep' returned with non-zero return code: " + str(e.returncode))
                matches = ''

            for tag in tags:
                if tag in matches:  # count only non-zero
                    suggested_tags.append((tag, matches.count(tag)))

            suggested_tags = sorted(
                suggested_tags, key=lambda x: x[1], reverse=True)
            suggested_tags = [st[0] for st in suggested_tags]

            if len(suggested_tags) > 0:
                click.echo("Suggested tags: ", nl=False)
                print_tags(suggested_tags)

        # returns array of tags
        tags = prompt_for_tags(
            ctx, "Please enter tag(s) for '" + click.style(citation_key, fg="cyan") + "'")

    for tag in tags:
        if tag_paper(ck_tag_dir, ck_bib_dir, citation_key, tag):
            click.secho("Added '" + tag + "' tag", fg="green")
        else:
            # When invoked by ck_{queue/read/finished}_cmd, we want this silenced
            if not silent:
                click.secho(citation_key + " already has '" +
                            tag + "' tag", fg="red", err=True)


@ck.command('rm')
@click.argument('citation_key', required=True, type=click.STRING)
@click.option(
    '-f', '--force',
    is_flag=True,
    default=False,
    help='Do not prompt for confirmation before deleting'
)
@click.pass_context
def ck_rm_cmd(ctx, force, citation_key):
    """Removes the paper from the library (.pdf and .bib file). Can provide citation key or filename with .pdf or .bib extension."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    # allow user to provide file name directly (or citation key to delete everything)
    basename, extension = os.path.splitext(citation_key)

    if len(extension.strip()) > 0:
        files = [os.path.join(ck_bib_dir, citation_key)]
    else:
        files = [ck_to_pdf(ck_bib_dir, citation_key),
                 ck_to_bib(ck_bib_dir, citation_key)]

    something_to_del = False
    for f in files:
        if os.path.exists(f):
            something_to_del = True

    if force or something_to_del:
        if not force:
            if not click.confirm("Are you sure you want to delete '" + citation_key + "' from the library?"):
                click.echo("Okay, not deleting anything.")
                return

        for f in files:
            if os.path.exists(f):
                os.remove(f)
                click.secho("Deleted " + f, fg="green")
            else:
                print_warning(f + " does not exist, nothing to delete...")

        # untag the paper
        untag_paper(ck_tag_dir, citation_key)
    else:
        click.echo(citation_key + " is not in library. Nothing to delete.")


@ck.command('open')
@click.argument('filename', required=True, type=click.STRING)
@click.pass_context
def ck_open_cmd(ctx, filename):
    """Opens the .pdf or .bib file."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_open = ctx.obj['OpenCmd']
    ck_text_editor = ctx.obj['TextEditor']
    ck_markdown_editor = ctx.obj['MarkdownEditor']
    ck_tags = ctx.obj['tags']

    ck_open = ck_open.split()
    citation_key, extension = os.path.splitext(filename)

    if len(extension.strip()) == 0:
        filename = citation_key + ".pdf"
        extension = '.pdf'

    fullpath = os.path.join(ck_bib_dir, filename)

    # The BibTeX might be in bad shape (that's why the user is using ck_open_cmd to edit) so ck_info_cmd, might throw
    if extension.lower() != '.bib':
        ctx.invoke(ck_info_cmd, citation_key=citation_key)

    if extension.lower() == '.pdf':
        if os.path.exists(fullpath) is False:
            print_error(citation_key +
                        " paper is NOT in the library as a PDF.")
            sys.exit(1)

        # not interested in output
        completed = subprocess.run(
            ck_open + [fullpath],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        if completed.returncode != 0:
            print_error("Could not open " + fullpath)
            sys.exit(1)
    elif extension.lower() == '.bib':
        os.system(ck_text_editor + " " + fullpath)

        # After the user successfully edited the file, we add the correct citation key and the 'ckdateadded' field
        if os.path.exists(fullpath):

            try:
                bibent = bibent_from_file(fullpath)

                # make sure the .bib file always has the right citation key
                bibent['ID'] = citation_key

                # warn if bib file is missing 'ckdateadded' field
                if 'ckdateadded' not in bibent:
                    bibent_set_dateadded(bibent, None)

                # write back the file
                bibent_to_file(fullpath, bibent)
                bibent = filter_bib_entry(bibent)
                to_print = bibent_to_bibtex(bibent)
                print(to_print)
            except:
                print_warning("Could not parse BibTeX:")
                traceback.print_exc()
    elif extension.lower() == '.tex':
        os.system(ck_text_editor + " " + fullpath)
    elif extension.lower() == '.md':
        # NOTE: Need to cd to the directory first so vim picks up the .vimrc there
        os.system('cd "' + ck_bib_dir + '" && ' +
                  ck_markdown_editor + ' "' + filename + '"')
    elif extension.lower() == '.html':
        if os.path.exists(fullpath) is False:
            print_error("No HTML notes in the library for '" +
                        citation_key + "'.")
            sys.exit(1)

        completed = subprocess.run(
            ck_open + [fullpath],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if completed.returncode != 0:
            print_error("Could not open " + fullpath)
            sys.exit(1)
    else:
        print_error(extension.lower() + " extension is not supported.")
        sys.exit(1)


def filter_bib_entry(bibent):
    camera_keys = {
        'author', 'booktitle', 'doi', 'howpublished', 'journal',
        'note', 'series', 'title', 'url', 'urldate', 'year'
    }

    filtered_bibent = {
        k: v for k, v in bibent.items()
        if k.isupper() or k in camera_keys
    }

    return filtered_bibent


@ck.command('bib')
@click.argument('citation_key', required=True, type=click.STRING)
@click.option(
    '--clipboard/--no-clipboard',
    default=True,
    help='To (not) copy the BibTeX to clipboard.'
)
@click.option(
    '-b', '--bibtex', 'fmt', flag_value='bibtex',
    default=True,
    help='Output as a BibTeX citation'
)
@click.option(
    '-m', '--markdown', 'fmt', flag_value='markdown',
    default=False,
    help='Output as a Markdown citation'
)
@click.option(
    '-t', '--text', 'fmt', flag_value='text',
    default=False,
    help='Output as a plain text citation'
)
@click.pass_context
def ck_bib_cmd(ctx, citation_key, clipboard, fmt):
    """Returns a bib for camera ready. Drops unncessary attributes. See `ck fullbib --help` for alternative."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']

    path = ck_to_bib(ck_bib_dir, citation_key)
    if os.path.exists(path) is False:
        if click.confirm(citation_key + " has no .bib file. Would you like to create it?"):
            ctx.invoke(ck_open_cmd, filename=citation_key + ".bib")
        else:
            click.echo("Okay, will NOT create .bib file. Exiting...")
            sys.exit(1)

    # Parse the BibTeX
    bibent = bibent_from_file(path)
    # Filtered bibent
    bibent = filter_bib_entry(bibent)

    if fmt == "bibtex":
        click.echo("Camera ready BibTeX for '%s'" % path, err=True)
        click.echo()

        to_copy = bibent_to_bibtex(bibent)
        to_print = to_copy
    elif fmt == "markdown":
        to_copy = bibent_to_markdown(bibent)
        # For Markdown bib's, we print exactly what we copy!
        to_print = to_copy
    elif fmt == "text":
        to_copy = bibent_to_text(bibent)
        # For plain text bib's, we print exactly what we copy!
        to_print = to_copy
    else:
        print_error("Code for parsing the citation format is wrong.")
        sys.exit(1)

    click.secho(to_print, fg='cyan')

    if clipboard:
        pyperclip.copy(to_copy)
        click.echo(err=True)
        # NOTE: We print to stderr since we want to allow the user to send the BibTeX output of 'ck genbib TXN20 >>references.bib' to a .bib file.
        if fmt != "bibtex":
            click.echo("Copied to clipboard!", err=True)
        else:
            click.echo("Copied to clipboard!", err=True)


@ck.command('fullbib')
@click.argument('citation_key', required=True, type=click.STRING)
@click.option(
    '--clipboard/--no-clipboard',
    default=True,
    help='To (not) copy the BibTeX to clipboard.'
)
@click.option(
    '-b', '--bibtex', 'fmt', flag_value='bibtex',
    default=True,
    help='Output as a BibTeX citation'
)
@click.option(
    '-m', '--markdown', 'fmt', flag_value='markdown',
    default=False,
    help='Output as a Markdown citation'
)
@click.option(
    '-t', '--text', 'fmt', flag_value='text',
    default=False,
    help='Output as a plain text citation'
)
@click.pass_context
def ck_fullbib_cmd(ctx, citation_key, clipboard, fmt):
    """Prints the paper's BibTeX and copies it to the clipboard."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']

    path = ck_to_bib(ck_bib_dir, citation_key)
    if os.path.exists(path) is False:
        if click.confirm(citation_key + " has no .bib file. Would you like to create it?"):
            ctx.invoke(ck_open_cmd, filename=citation_key + ".bib")
        else:
            click.echo("Okay, will NOT create .bib file. Exiting...")
            sys.exit(1)

    # Parse the BibTeX
    bibent = bibent_from_file(path)
    has_abstract = False

    if fmt == "bibtex":
        click.echo("BibTeX for '%s'" % path, err=True)
        click.echo()

        # We print the full thing!
        to_print = bibent_to_bibtex(bibent)

        # We're not gonna copy the abstract to the clipboard, since usually we don't want it taking up space in .bib files of papers we're writing.
        has_abstract = 'abstract' in bibent
        bibent.pop('abstract', None)
        to_copy = bibent_to_bibtex(bibent)
    elif fmt == "markdown":
        to_copy = bibent_to_markdown(bibent)
        # For Markdown bib's, we print exactly what we copy!
        to_print = to_copy
    elif fmt == "text":
        to_copy = bibent_to_text(bibent)
        # For plain text bib's, we print exactly what we copy!
        to_print = to_copy
    else:
        print_error("Code for parsing the citation format is wrong.")
        sys.exit(1)

    click.secho(to_print, fg='cyan')

    if clipboard:
        pyperclip.copy(to_copy)
        click.echo(err=True)
        # NOTE: We print to stderr since we want to allow the user to send the BibTeX output of 'ck genbib TXN20 >>references.bib' to a .bib file.
        if fmt != "bibtex":
            click.echo("Copied to clipboard!", err=True)
        else:
            if has_abstract:
                click.echo(
                    "Copied to clipboard, but without the abstract!", err=True)
            else:
                click.echo("Copied to clipboard!", err=True)


@ck.command('rename')
@click.argument('old_citation_key', required=True, type=click.STRING)
@click.argument('new_citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_rename_cmd(ctx, old_citation_key, new_citation_key):
    """Renames a paper's .pdf and .bib file with a new citation key. Updates its .bib file and all symlinks to it in the TagDir."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags = ctx.obj['tags']

    # make sure old CK exists and new CK does not
    if not ck_exists(ck_bib_dir, old_citation_key):
        print_error("Old citation key '" +
                    old_citation_key + "' does NOT exist.")
        sys.exit(1)

    if ck_exists(ck_bib_dir, new_citation_key):
        print_error("New citation key '" +
                    new_citation_key + "' already exists.")
        sys.exit(1)

    # find all files associated with the CK
    files = glob.glob(os.path.join(ck_bib_dir, old_citation_key) + '.*')
    for f in files:
        path_noext, ext = os.path.splitext(f)
        # e.g.,
        # ('/Users/alinush/Dropbox/Papers/MBK+19', '.pdf')
        # ('/Users/alinush/Dropbox/Papers/MBK+19', '.bib')
        # ('/Users/alinush/Dropbox/Papers/MBK+19.slides', '.pdf')

        # dirname = os.path.dirname(path_noext)  # i.e., BibDir
        oldfilename = os.path.basename(path_noext)

        # replaces only the 1st occurrence of the old CK to deal with the (astronomically-rare?)
        # event where the old CK appears multiple times in the filename
        newfilename = oldfilename.replace(
            old_citation_key, new_citation_key, 1)
        click.echo("Renaming '" + oldfilename + ext + "' to '" +
                   newfilename + ext + "' in " + ck_bib_dir)

        # rename file in BibDir
        os.rename(
            os.path.join(ck_bib_dir, oldfilename + ext),
            os.path.join(ck_bib_dir, newfilename + ext))

    # update .bib file citation key
    click.echo("Renaming CK in BibTeX file...")
    bibpath_rename_ck(
        ck_to_bib(ck_bib_dir, new_citation_key), new_citation_key)

    # if the paper is tagged, update all symlinks in TagDir by un-tagging and re-tagging
    if old_citation_key in ck_tags:
        click.echo("Recreating tag information...")
        tags = ck_tags[old_citation_key]
        for tag in tags:
            if not untag_paper(ck_tag_dir, old_citation_key, tag):
                print_warning("Could not remove '" + tag + "' tag")

            if not tag_paper(ck_tag_dir, ck_bib_dir, new_citation_key, tag):
                print_warning("Already has '" + tag + "' tag")


@ck.command('search')
@click.argument('query', required=True, type=click.STRING)
@click.option(
    '-c', '--case-sensitive',
    is_flag=True,
    default=False,
    help='Enables case-sensitive search.'
)
@click.pass_context
def ck_search_cmd(ctx, query, case_sensitive):
    """Searches all .bib files for the specified text."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tags = ctx.obj['tags']

    cks = set()
    for relpath in os.listdir(ck_bib_dir):
        filepath = os.path.join(ck_bib_dir, relpath)
        filename, extension = os.path.splitext(relpath)
        # filename = os.path.basename(filepath)

        if extension.lower() == ".bib":
            origBibtex = file_to_string(filepath)

            if case_sensitive is False:
                bibtex = origBibtex.lower()
                query = query.lower()

                if query in bibtex:
                    cks.add(filename)

    if len(cks) > 0:
        include_url = True
        include_venue = True

        ck_tuples = cks_to_tuples(ck_bib_dir, cks, verbosity)

        # NOTE: Currently sorts alphabetically by CK
        sorted_cks = sorted(ck_tuples, key=lambda item: item[0])

        print_ck_tuples(sorted_cks, ck_tags, include_url, include_venue)
    else:
        print("No matches!")


@ck.command('cleanbib')
@click.pass_context
def ck_cleanbib_cmd(ctx):
    """Command to clean up the .bib files a little. (Temporary, until I write something better.)"""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = os.path.normpath(os.path.realpath(ctx.obj['TagDir']))

    cks = list_cks(ck_bib_dir, False)

    for ck in cks:
        bibfile = ck_to_bib(ck_bib_dir, ck)
        if verbosity > 1:
            print("Parsing BibTeX for " + ck)
        try:
            with open(bibfile) as bibf:
                bibtex = bibtexparser.load(bibf, new_bibtex_parser())

            assert len(bibtex.entries) == 1
            assert type(ck) == str
            updated = bibent_canonicalize(ck, bibtex.entries[0], verbosity)

            if updated:
                print("Updating " + bibfile)
                bibwriter = BibTexWriter()
                with open(bibfile, 'w') as bibf:
                    bibf.write(bibwriter.write(bibtex))
            else:
                if verbosity > 0:
                    print("Nothing to update in " + bibfile)

        except FileNotFoundError:
            print(ck + ":", "Missing BibTeX file in directory", ck_bib_dir)
        except:
            print(ck + ":", "Unexpected error")
            traceback.print_exc()


@ck.command('list')
@click.argument('tag_names_or_subdirs', nargs=-1, type=click.STRING)
@click.option(
    '-a', '--anonymize',
    is_flag=True,
    default=False,
    help='Lists without including info like CK, date added and tags, which could be linked back to this machine'
)
@click.option(
    '-r', '--recursive',
    is_flag=True,
    default=False,
    help='Recursively lists all CKs in the specified location'
)
@click.option(
    '-c', '--ck-only',
    is_flag=True,
    default=False,
    help='Citation keys only'
)
@click.option(
    '-s', '--sort',
    default='date-added',
    help='Sorts either by CK, title, author, year, date-added, or venue'
)
@click.option(
    '-t', '--tags', 'is_tags',
    is_flag=True,
    default=False,
    help='Interprets all arguments as tags.'
)
@click.option(
    '-u', '--url',
    is_flag=True,
    default=False,
    help='Includes the URLs next to each paper'
)
@click.pass_context
# WARNING: The bash autocompletion script relies on this command working as it does now.
# WARNING: Do not make this any more complicated than it is!
#
# This command serves three purposes right now, which is why it's a bit messy:
# 1. Let the user navigate the TagDir via the command line by using 'ck l' and 'ck l <tag-or-subtag>'.
# 2. List papers with specific tags via -t/--tags (which could be delegated to 'ck search' or some other command).
# 3. List all papers in the library (when doing 'ck l' outside the TagDir)
def ck_list_cmd(ctx, tag_names_or_subdirs, anonymize, recursive, ck_only, sort, is_tags, url):
    """Lists all citation keys in the specified subdirectories of TagDir or if -t/--tags is passed, all citation keys with the specified tags.

    TAG_NAMES_OR_SUBDIRS is by default assumed to be a list of subdirectories of TagDir, but if -t/--tags is passed, then it is interpreted as a list of tags."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = os.path.normpath(os.path.realpath(ctx.obj['TagDir']))
    ck_tags = ctx.obj['tags']

    cks = set()

    if is_tags:
        # If arguments are tags, then list by tags
        tags = tag_names_or_subdirs
        cks.update(cks_from_tags(ck_tag_dir, tags, recursive))
    else:
        subdirs = []
        subdirs.extend(tag_names_or_subdirs)
        if len(subdirs) == 0:
            # If no TagDir subdir args were given, and...
            if is_cwd_in_tagdir(ck_tag_dir):
                # ...we are in the TagDir, list the current TagDir subdirectory
                subdirs.append(os.getcwd())
            else:
                # ...we are NOT in the TagDir, list the BibDir
                subdirs.append(ck_bib_dir)

        for subdir in subdirs:
            if os.path.exists(subdir):
                cks.update(list_cks(subdir, recursive))
            else:
                print_warning("Directory '" + subdir + "' does not exist")

    if ck_only:
        if len(cks) > 0:
            click.echo(' '.join(sorted(cks)))
    else:
        # TODO: changing the ordering of the columns in a tuple will mess up sorting below
        ck_tuples = cks_to_tuples(ck_bib_dir, cks, verbosity)

        if sort.lower() == "ck":
            sort_idx = 0
        elif sort.lower() == "author":
            sort_idx = 1
        elif sort.lower() == "title":
            sort_idx = 2
        elif sort.lower() == "year":
            sort_idx = 3
        elif sort.lower() == "date-added":
            sort_idx = 4
        elif sort.lower() == "venue":
            sort_idx = 6
        else:
            print_warning("Unknown sorting index ('" + sort +
                          "'), defaulting to 'date-added'")
            sort = 'date-added'
            sort_idx = 4  # date-added

        sorted_cks = sorted(ck_tuples, key=lambda item: item[sort_idx])

        include_ck = False if anonymize else True
        include_dateadded = False if anonymize else True
        include_tags = False if anonymize else True

        print_ck_tuples(sorted_cks, ck_tags, url, include_ck=include_ck,
                        include_dateadded=include_dateadded, include_tags=include_tags)

        click.echo(str(len(cks)) + " PDFs listed (sorted by " + sort + ")")


@ck.command('genbib')
@click.argument('output-file', required=True, type=click.File('a'))
@click.argument('tags', required=False, nargs=-1, type=click.STRING)
@click.option(
    '-b', '--bibtex', 'fmt', flag_value='bibtex',
    default=True,
    help='Outputs bibliography in BibTeX format'
)
@click.option(
    '-m', '--markdown', 'fmt', flag_value='markdown',
    default=False,
    help='Outputs bibliography in Markdown format'
)
@click.option(
    '-t', '--text', 'fmt', flag_value='text',
    default=False,
    help='Outputs bibliography in plain text format'
)
@click.option(
    '-r', '--recursive',
    is_flag=True,
    default=False,
    help='Includes CKs that are recursively-tagged too.'
)
@click.pass_context
def ck_genbib_cmd(ctx, output_file, tags, fmt, recursive):
    """Generates a bibliography file of papers tagged with the specified tags.
       If the specified bibliography file already exists, just appends to it.
       If no tags are given, generates a bibliography file of all papers in the BibDir."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    tags = tags_filter_whitespace(tags)

    if len(tags) == 0:
        cks = list_cks(ck_bib_dir, False)
    else:
        cks = cks_from_tags(ck_tag_dir, tags, recursive)

    num_copied = 0
    for ck in sorted(cks):
        try:
            bibfilepath = ck_to_bib(ck_bib_dir, ck)

            if os.path.exists(bibfilepath):
                num_copied += 1

                bibtex = file_to_string(bibfilepath)
                bibent = bibtex_to_bibent(bibtex)
                if fmt == "bibtex":
                    bibstr = bibtex
                elif fmt == "markdown":
                    bibstr = bibent_to_markdown(bibent)
                elif fmt == "text":
                    bibstr = bibent_to_text(bibent)
                else:
                    print_error("Unknown bibliography format: " + fmt)
                    sys.exit(1)

                bibstr = bibstr.strip()
                output_file.write(bibstr + '\n\n')
        except:
            print_error(
                "Something went wrong while parsing BibTeX for " + style_ck(ck))

    if num_copied == 0:
        print_warning("No BibTeX entries were written to '" +
                      output_file.name + "'")
    else:
        print_success("Wrote " + str(num_copied) +
                      " BibTeX entries to '" + output_file.name + "'")


@ck.command('copypdfs')
@click.argument('output-dir', required=True, type=click.Path(exists=True, file_okay=False, dir_okay=True, resolve_path=True))
@click.argument('tags', required=True, nargs=-1, type=click.STRING)
@click.option(
    '-r', '--recursive',
    is_flag=True,
    default=False,
    help='Copies CKs that are recursively-tagged too.'
)
@click.pass_context
def ck_copypdfs_cmd(ctx, output_dir, tags, recursive):
    """Copies all PDFs tagged with the specified tags into the specified output directory."""

    ctx.ensure_object(dict)
    verbosity = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    tags = tags_filter_whitespace(tags)
    cks = cks_from_tags(ck_tag_dir, tags, recursive)

    num_copied = 0
    for ck in cks:
        if ck_exists(ck_bib_dir, ck):
            destfile = os.path.join(output_dir, ck + ".pdf")
            if not os.path.exists(destfile):
                shutil.copy2(ck_to_pdf(ck_bib_dir, ck), output_dir)
                num_copied += 1
            else:
                print_warning("PDF for " + ck +
                              " already exists in " + output_dir)
        else:
            print_warning(
                style_ck(ck) + " PDF not found in '" + ck_bib_dir + "'")

    if num_copied == 0:
        print_warning("No PDFs were copied.")
    else:
        print_success("Copied " + str(num_copied) +
                      " PDFs to '" + output_dir + "'")


if __name__ == '__main__':
    ck(obj={})
