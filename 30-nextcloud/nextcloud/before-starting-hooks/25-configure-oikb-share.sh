#!/bin/sh
set -eu

if [ ! -f /var/www/html/config/config.php ]; then
  exit 0
fi

: "${NEXTCLOUD_OIKB_SHARE_OWNER:=admin}"
: "${NEXTCLOUD_OIKB_SHARE_PATH:=/oikb}"
: "${NEXTCLOUD_OIKB_SHARE_GROUP:=users}"
: "${NEXTCLOUD_OIKB_SHARE_PERMISSIONS:=31}"

export NEXTCLOUD_OIKB_SHARE_OWNER
export NEXTCLOUD_OIKB_SHARE_PATH
export NEXTCLOUD_OIKB_SHARE_GROUP
export NEXTCLOUD_OIKB_SHARE_PERMISSIONS

php <<'PHP'
<?php

declare(strict_types=1);

require_once '/var/www/html/lib/base.php';

$owner = getenv('NEXTCLOUD_OIKB_SHARE_OWNER') ?: 'admin';
$path = getenv('NEXTCLOUD_OIKB_SHARE_PATH') ?: '/oikb';
$groupId = getenv('NEXTCLOUD_OIKB_SHARE_GROUP') ?: 'users';
$permissions = (int)(getenv('NEXTCLOUD_OIKB_SHARE_PERMISSIONS') ?: '31');

if (!str_starts_with($path, '/')) {
	$path = '/' . $path;
}

$server = \OC::$server;
$groupManager = $server->get(\OCP\IGroupManager::class);
$userManager = $server->get(\OCP\IUserManager::class);
$rootFolder = $server->get(\OCP\Files\IRootFolder::class);
$shareManager = $server->get(\OCP\Share\IManager::class);

if (!$userManager->userExists($owner)) {
	throw new RuntimeException("OIKB share owner does not exist: {$owner}");
}

$group = $groupManager->get($groupId) ?? $groupManager->createGroup($groupId);
if ($group === null) {
	throw new RuntimeException("OIKB share group could not be created: {$groupId}");
}

// 既存利用者も共有対象になるよう、所有者以外を共有用groupへ寄せる。
/**
 * 共有用groupへ既存利用者を追加する。
 *
 * @param \OCP\IUser $user 追加対象として確認するNextcloud利用者。
 * @return void 戻り値はありません。
 */
$userManager->callForAllUsers(static function (\OCP\IUser $user) use ($group, $owner): void {
	if ($user->getUID() !== $owner && !$group->inGroup($user)) {
		$group->addUser($user);
	}
});

$userFolder = $rootFolder->getUserFolder($owner);
if (!$userFolder->nodeExists($path)) {
	$userFolder->newFolder(ltrim($path, '/'));
}

$node = $userFolder->get($path);
if (!$node instanceof \OCP\Files\Folder) {
	throw new RuntimeException("OIKB share path is not a folder: {$path}");
}

$shares = $shareManager->getSharesBy($owner, \OCP\Share\IShare::TYPE_GROUP, $node, false, 100, 0);
foreach ($shares as $share) {
	if ($share->getSharedWith() === $groupId) {
		if ($share->getPermissions() !== $permissions) {
			$share->setPermissions($permissions);
			$shareManager->updateShare($share);
			echo "Updated OIKB group share: {$path} -> {$groupId}\n";
		} else {
			echo "OIKB group share already exists: {$path} -> {$groupId}\n";
		}
		exit(0);
	}
}

$share = $shareManager->newShare();
$share->setNode($node);
$share->setShareType(\OCP\Share\IShare::TYPE_GROUP);
$share->setSharedWith($groupId);
$share->setSharedBy($owner);
$share->setPermissions($permissions);
$shareManager->createShare($share);

echo "Created OIKB group share: {$path} -> {$groupId}\n";
PHP
