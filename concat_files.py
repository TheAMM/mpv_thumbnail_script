#!/usr/bin/env python3
import re
import os
import time
import json
import binascii

import argparse
import hashlib
import subprocess
import datetime


parser = argparse.ArgumentParser(
    description="Concatenate files to a target file, optionally writing target-changes back to source files"
)

parser.add_argument('config_file', metavar='CONFIG_FILE', help='Configuration file for concat')
parser.add_argument('-o', '--output', metavar='OUTPUT', help='Override output filename')
parser.add_argument(
    '-w',
    '--watch',
    action='store_true',
    help='Watch files for any changes and map them between the target and source files',
)
parser.add_argument('-r', '--release', action='store_true', help='Build a version without the section dividers')


class FileWatcher(object):
    def __init__(self, file_list=[]):
        self.file_list = file_list
        self._mtimes = self._get_mtimes()

    def _get_mtimes(self):
        return {filename: os.path.getmtime(filename) for filename in self.file_list if os.path.exists(filename)}

    def get_changes(self):
        mtimes = self._get_mtimes()
        changes = [filename for filename in self.file_list if self._mtimes.get(filename, 0) < mtimes.get(filename, 0)]
        self._mtimes.update(mtimes)
        return changes


class FileSection(object):
    def __init__(self, filename, content, modified):
        self.filename = filename
        self.content = content
        self.modified = modified
        self.hash = None

        self.old_hash = None

        if self.content:
            self.recalculate_hash()

    def __repr__(self):
        hash_part = binascii.hexlify(self.hash).decode()[:7]
        if self.old_hash:
            hash_part += ' (' + binascii.hexlify(self.old_hash).decode()[:7] + ')'

        return '<{} \'{}\' {}b {}>'.format(self.__class__.__name__, self.filename, len(self.content), hash_part)

    def recalculate_hash(self):
        self.hash = hashlib.sha256(self.content.encode('utf-8')).digest()
        return self.hash

    @classmethod
    def from_file(cls, filename):
        modified_time = os.path.getmtime(filename)
        with open(filename, 'r', encoding='utf-8') as in_file:
            content = in_file.read()

        return cls(filename=filename, content=content, modified=modified_time)
        # hash=hash)


class Concatter(object):
    SECTION_REGEX_BASE = r'FileConcat-([SE]) (.+?) HASH:(.+?)'
    SECTION_HEADER_FORMAT_BASE = 'FileConcat-{kind} {filename} HASH:{hash}'

    def __init__(self, config, working_directory=''):
        self.output_filename = config.get('output', 'output.txt')
        self.file_list = config.get('files', [])
        self.section_header_prefix = config.get('header_prefix', '')
        self.section_header_suffix = config.get('header_suffix', '')
        self.working_directory = working_directory

        self.version_metafile = None

        self.newline = '\n'

        self.section_header_format = (
            self.section_header_prefix + self.SECTION_HEADER_FORMAT_BASE + self.section_header_suffix
        )
        self.section_header_regex = re.compile(
            r'^'
            + re.escape(self.section_header_prefix)
            + self.SECTION_REGEX_BASE
            + re.escape(self.section_header_suffix)
            + r'$'
        )

    def split_output_file(self):
        file_sections = []
        if not os.path.exists(self.output_filename):
            return file_sections

        modified_time = os.path.getmtime(self.output_filename)
        with open(self.output_filename, 'r', encoding='utf-8') as in_file:
            current_section = None
            section_lines = []

            for line in in_file:
                header_match = self.section_header_regex.match(line)
                if header_match:
                    is_start = header_match.group(1) == 'S'
                    section_filename = header_match.group(2)
                    section_hash = binascii.unhexlify(header_match.group(3))

                    if is_start and current_section is None:
                        current_section = FileSection(section_filename, None, modified_time)
                    elif not is_start and current_section:
                        current_section.content = ''.join(section_lines)
                        current_section.recalculate_hash()
                        current_section.old_hash = section_hash

                        file_sections.append(current_section)

                        current_section = None
                        section_lines = []
                else:
                    section_lines.append(line)

            if current_section is not None:
                raise Exception('Missing file end marker! For ' + current_section.filename)

        return file_sections

    def read_source_files(self):
        file_sections = []

        for filename in self.file_list:
            # The version metafile
            if filename == '<version>':
                file_section = self.version_metafile
            else:
                file_path = os.path.join(self.working_directory, filename)
                if not os.path.exists(file_path):
                    raise Exception("File '{}' is missing!".format(file_path))

                file_section = FileSection.from_file(file_path)
                file_section.filename = filename

                # Figure out newline to be used
                # if self.newline is None:
                # self.newline = '\r\n' if '\r\n' in file_section.content else '\n'

                if not file_section.content.endswith(self.newline):
                    file_section.content += self.newline
                    file_section.recalculate_hash()

            file_sections.append(file_section)
        return file_sections

    def concatenate_file_sections(self, file_sections, insert_section_headers=True):
        with open(self.output_filename, 'w', newline='\n', encoding='utf-8') as out_file:
            for file_section in file_sections:
                if insert_section_headers:
                    section_hash = binascii.hexlify(file_section.recalculate_hash()).decode()

                    out_file.write(
                        self.section_header_format.format(kind='S', filename=file_section.filename, hash=section_hash)
                        + self.newline
                    )
                    out_file.write(file_section.content)
                    out_file.write(
                        self.section_header_format.format(kind='E', filename=file_section.filename, hash=section_hash)
                        + self.newline
                    )
                else:
                    out_file.write(file_section.content)

    def write_file_sections_back(self, file_sections):
        for file_section in file_sections:
            # Skip version metafile
            if file_section is self.version_metafile:
                continue

            file_path = os.path.join(self.working_directory, file_section.filename)

            # Backup target file if it exists
            if os.path.exists(file_path):
                bak_filename = file_path + '.bak'
                if os.path.exists(bak_filename):
                    os.remove(bak_filename)
                os.rename(file_path, bak_filename)

            # Write contents
            with open(file_path, 'w', newline='\n', encoding='utf-8') as out_file:
                out_file.write(file_section.content)

    def _map_sections(self, source_sections, target_sections):
        target_map = {s.filename: s for s in target_sections}

        source_to_target = []
        target_to_source = []

        for source_section in source_sections:
            if source_section is self.version_metafile:
                continue

            target_section = target_map.get(source_section.filename)

            if not target_section:
                # Target doesn't have this section at all (or is completely empty)
                source_to_target.append(source_section)  # Write section to target file
            else:
                source_section.old_hash = target_section.old_hash  # Used to check changes on rewrite
                source_newer = source_section.modified > target_section.modified

                # Target and source differ
                if source_section.hash != target_section.hash:
                    if source_newer:
                        # If source file is newer than target, use it
                        source_to_target.append(source_section)
                    else:
                        # Use target section to rewrite target section AND source file
                        target_section.old_hash = target_section.hash  # Hack to skip target rewrite
                        source_to_target.append(target_section)
                        target_to_source.append(target_section)
                else:
                    # No change in files so just use the source file
                    source_to_target.append(source_section)

        return source_to_target, target_to_source

    def process_changes_in_files(self):
        source_sections = self.read_source_files()
        target_sections = self.split_output_file()

        source_to_target, target_to_source = self._map_sections(source_sections, target_sections)

        changed_sections = [s for s in source_to_target if s.hash != s.old_hash]
        if changed_sections:
            self.concatenate_file_sections(source_to_target)

        if target_to_source:
            self.write_file_sections_back(target_to_source)

        return changed_sections, target_to_source

    def plain_concat(self):
        source_sections = self.read_source_files()
        self.concatenate_file_sections(source_sections, False)


def _create_version_metafile(config, config_dirname):
    repo_dir = os.path.join(config_dirname, config.get('repo_dir', ''))
    try:
        git_branch = (
            subprocess.check_output(
                ['git', '-C', repo_dir, 'symbolic-ref', '--short', '-q', 'HEAD'], stderr=subprocess.DEVNULL
            )
            .decode()
            .strip()
        )
        git_commit = (
            subprocess.check_output(
                ['git', '-C', repo_dir, 'rev-parse', '--short', '-q', 'HEAD'], stderr=subprocess.DEVNULL
            )
            .decode()
            .strip()
        )
        git_tag = (
            subprocess.check_output(
                ['git', '-C', repo_dir, 'describe', '--tags', '--abbrev=0'], stderr=subprocess.DEVNULL
            )
            .decode()
            .strip()
        )
    except:
        git_branch = None
        git_commit = None
        git_tag = None

    if not git_branch:
        git_branch = 'unknown'

    if git_commit:
        git_commit_short = git_commit[:7]
    else:
        git_commit = git_commit_short = 'unknown'

    if not git_tag:
        git_tag = 'unknown'

    template_data = {
        'version': git_tag,
        'branch': git_branch,
        'commit': git_commit,
        'commit_short': git_commit_short,
        'now': datetime.datetime.now(),
        'utc_now': datetime.datetime.utcnow(),
    }

    version_template_file = config.get('version_template_file')
    if version_template_file:
        with open(os.path.join(config_dirname, version_template_file), 'r') as in_file:
            version_template = in_file.read()
    else:
        version_template = ''

    version_metafile = FileSection('<version>', version_template.format(**template_data), 0)
    return version_metafile


def _print_change_writes(source_to_target, target_to_source):
    if source_to_target:
        print('SOURCE -> TARGET')
        print(source_to_target)
    if target_to_source:
        print('TARGET -> SOURCE')
        print(target_to_source)
    if not source_to_target and not target_to_source:
        print('No changes.')


if __name__ == '__main__':
    args = parser.parse_args()

    if not os.path.exists(args.config_file):
        print('Unable to find given configuration file \'{}\''.format(args.config_file))
        exit(1)

    try:
        with open(args.config_file, 'r') as in_file:
            config = json.load(in_file)
    except:
        print('Unable to read given configuration file \'{}\''.format(args.config_file))
        exit(1)

    config_dirname = os.path.dirname(args.config_file)
    if args.output:
        config['output'] = args.output
    else:
        # Make output be relative to config file
        config['output'] = os.path.join(config_dirname, config['output'])

    concatter = Concatter(config, config_dirname)
    concatter.version_metafile = _create_version_metafile(config, config_dirname)

    if not concatter.file_list:
        print('No files listed in configuration!')
        exit(1)

    if not args.watch:
        if args.release:
            concatter.plain_concat()
            print("Concatenated source files to '{}'".format(concatter.output_filename))
        else:
            s2t, t2s = concatter.process_changes_in_files()
            _print_change_writes(s2t, t2s)
    else:
        tracked_files_list = list(concatter.file_list)
        tracked_files_list.append(concatter.output_filename)

        file_watcher = FileWatcher(tracked_files_list)

        print('Watching changes for', len(tracked_files_list), 'files...')
        while True:
            changes = file_watcher.get_changes()

            if changes:
                print("------------------------", changes)
                if args.release:
                    concatter.plain_concat()
                    print("Concatenated source files to '{}'".format(concatter.output_filename))
                else:
                    s2t, t2s = concatter.process_changes_in_files()
                    _print_change_writes(s2t, t2s)
                # Grab new mtimes
                file_watcher.get_changes()

            time.sleep(0.25)
