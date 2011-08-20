/*
 * Copyright (c) 2011 Novell Inc., Tim Serong <tserong@novell.com>
 *                        All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of version 2 of the GNU General Public License as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it would be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * Further, this software is distributed without any warranty that it is
 * free of the rightful claim of any third person regarding infringement
 * or the like.  Any license provided herein, whether implied or
 * otherwise, applies only to this software file.  Patent licenses, if
 * any, provided herein do not apply to combinations of this program with
 * other software, or any other product whatsoever.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write the Free Software Foundation,
 * Inc., 59 Temple Place - Suite 330, Boston MA 02111-1307, USA.
 */

/*
 * hawk_invoke allows the hacluster user to run a small assortment of
 * Pacemaker CLI tools as another user, in order to support Pacemaker's
 * ACL feature.
 *
 * hawk_invoke:
 * - must be installed setuid root
 * - will refuse to run if invoked by anyone other than "root" or
 *   "hacluster"
 * - will only setuid() to a non-root user in the "haclient" group.
 * - will in turn only invoke a specific small set of Pacemaker
 *   CLI commands.
 *
 * The idea here is that hawk_invoke:
 * - Will allow "hacluster" or "root" to become a less-privileged
 *   user for the purposes of cluster administration.
 * - Will not allow the "hacluster" user to become a more-privileged
 *   user.
 * - Will not allow arbitrary commands to be executed as any other
 *   user.
 *
 * Usage:
 *
 *  /usr/sbin/hawk_invoke <username> <command> [args ...]
 *
 * Where:
 *
 *  username  = name of the user to run command as
 *  command   = short name of command (e.g.: "crm_mon")
 *  args      = any args for command
 *
 */

#include <unistd.h>
#include <sys/types.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>
#include <grp.h>
#include "common.h"

struct cmd_map
{
	const char *name;	/* Short name of command */
	const char *path;	/* Full path to actual command */
};

static struct cmd_map commands[] = {
	{"cibadmin",		SBINDIR"/cibadmin"},
	{"crm",			SBINDIR"/crm"},
	{"crmadmin",		SBINDIR"/crmadmin"},
	{"crmd",		LIBDIR"/heartbeat/crmd"},
	{"crm_attribute",	SBINDIR"/crm_attribute"},
	{"crm_mon",		SBINDIR"/crm_mon"},
	{"pengine",		LIBDIR"/heartbeat/pengine"},
	{NULL, NULL}
};

static void die(const char *format, ...)
{
	va_list args;
	va_start(args, format);
	vfprintf(stderr, format, args);
	va_end(args);
	exit(1);
}

int main(int argc, char **argv)
{
	uid_t uid;
	struct passwd *pwd;
	struct group *grp;
	char *grp_user;
	int i;
	int found = 0;
	struct cmd_map *cmd;
	char *home = NULL;

	if (argc < 3) {
		die("Usage: %s <username> <command> [args ...]\n", argv[0]);
	}

	/* Ensure we're being run by either root or hacluster */
	uid = getuid();
	if (uid != 0) {
		/* Not root, let's see if we're running as hacluster */
		pwd = getpwuid(uid);
		if (pwd == NULL || strcmp(pwd->pw_name, HACLUSTER) != 0) {
			/*
			 * Not hacluster either.
			 * TODO: log this to syslog, to alert sysadmin
			 * of potential nefarious local user.
			 */
			die("ERROR: Permission denied\n");
		}
	}

	/* See who we're trying to become... */
	pwd = getpwnam(argv[1]);
	if (pwd == NULL) {
		die("ERROR: User '%s' not found\n", argv[1]);
	}

	/*
	 * Don't become root!
	 * (Is there really any sense checking for pw_name == "root"?
	 */
	if (pwd->pw_uid == 0 || strcmp(pwd->pw_name, "root") == 0) {
		die("ERROR: Thou shalt not become root\n");
	}

	/* Make sure the new user is in the haclient group */
	grp = getgrgid(pwd->pw_gid);
	if (grp == NULL) {
		die("ERROR: Can't determine group for user '%s'\n", pwd->pw_name);
	}
	if (strcmp(grp->gr_name, HACLIENT) != 0) {
		/* Not the primary group, let's check the others */
		grp = getgrnam(HACLIENT);
		if (grp == NULL) {
			die("ERROR: Group '%s' does not exist\n", HACLIENT);
		}
		i = 0;
		found = 0;
		while ((grp_user = grp->gr_mem[i]) != NULL) {
			if (strcmp(grp_user, pwd->pw_name) == 0) {
				found = 1;
				break;
			}
			i++;
		}
		if (!found) {
			die("ERROR: User '%s' is not in the '%s' group\n", pwd->pw_name, HACLIENT);
		}
	}

	/* Verify the command to execute is valid, and expand it */
	found = 0;
	for (cmd = commands; cmd->name != NULL; cmd++) {
		if (strcmp(cmd->name, argv[2]) == 0) {
			found = 1;
			break;
		}
	}
	if (!found) {
		die("ERROR: Invalid command '%s'\n", argv[2]);
	}
	/* (bit rough to drop const...) */
	argv[2] = (char *)cmd->path;

	/*
	 * Become the new user.  Note that at this point, grp still refers
	 * to the "haclient" group, either because that was the user's
	 * primary group, or because we looked that group up to search
	 * through its members.  Likewise pwd still refers to the user
	 * we're trying to become.
	 */
	if (setresgid(grp->gr_gid, grp->gr_gid, grp->gr_gid) != 0) {
		die("ERROR: Can't set group to '%s' (%d)\n", grp->gr_name, grp->gr_gid);
	}
	if (setresuid(pwd->pw_uid, pwd->pw_uid, pwd->pw_uid) != 0) {
		die("ERROR: Can't set user to '%s' (%d)\n", pwd->pw_name, pwd->pw_uid);
	}

	/*
	 * Bit of cleanup - is this in the right place, and is it really
	 * necessary?
	 */
	endpwent();
	endgrent();

	/* Clean up environment */
	home = getenv("HOME");
	if (home != NULL) {
		home = strdup(home);
	}
	if (clearenv() != 0) {
		die("ERROR: Can't clear environment");
	}
	setenv("PATH", SBINDIR":"BINDIR":/bin", 1);
	if (home != NULL) {
		setenv("HOME", home, 1);
	}

	/* And away we go... */
	execv(argv[2], &argv[2]);
	perror(argv[2]);
	return 1;
}
