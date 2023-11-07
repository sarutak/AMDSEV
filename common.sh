#!/bin/bash

run_cmd()
{
	echo "$*"

	eval "$*" || {
		echo "ERROR: $*"
		exit 1
	}
}

build_kernel()
{
	set -x
	kernel_type=$1
	shift
	mkdir -p linux
	pushd linux >/dev/null

	if [ ! -d guest ]; then
		run_cmd git clone ${KERNEL_GIT_URL} guest
		pushd guest >/dev/null
		run_cmd git remote add current ${KERNEL_GIT_URL}
		popd
	fi

	if [ ! -d host ]; then
		# use a copy of guest repo as the host repo
		run_cmd cp -r guest host
	fi

	for V in guest host; do
		# Check if only a "guest" or "host" or kernel build is requested
		if [ "$kernel_type" != "" ]; then
			if [ "$kernel_type" != "$V" ]; then
				continue
			fi
		fi

		if [ "${V}" = "guest" ]; then
			TAG="${KERNEL_GUEST_TAG}"
		else
			TAG="${KERNEL_HOST_TAG}"
		fi

		# If ${KERNEL_GIT_URL} is ever changed, 'current' remote will be out
		# of date, so always update the remote URL first. Also handle case
		# where AMDSEV scripts are updated while old kernel repos are still in
		# the directory without a 'current' remote
		pushd ${V} >/dev/null
		if git remote get-url current 2>/dev/null; then
			run_cmd git remote set-url current ${KERNEL_GIT_URL}
		else
			run_cmd git remote add current ${KERNEL_GIT_URL}
		fi
		popd >/dev/null

		# Nuke any previously built packages so they don't end up in new tarballs
		# when ./build.sh --package is specified
		rm -f linux-*-snp-${V}*

		VER="-snp-${V}"

		MAKE="make -C ${V} -j $(getconf _NPROCESSORS_ONLN) LOCALVERSION="

		run_cmd $MAKE distclean

		pushd ${V} >/dev/null
			run_cmd git fetch current
			run_cmd git checkout -b ${TAG} refs/tags/${TAG}
			COMMIT=$(git log --format="%h" -1 HEAD)

			run_cmd "cp /boot/kernel-config .config"
			run_cmd ./scripts/config --set-str LOCALVERSION "$VER-$COMMIT"
			run_cmd ./scripts/config --disable LOCALVERSION_AUTO
			run_cmd ./scripts/config --enable  EXPERT
			run_cmd ./scripts/config --enable  DEBUG_INFO
			run_cmd ./scripts/config --enable  DEBUG_INFO_REDUCED
			run_cmd ./scripts/config --enable  AMD_MEM_ENCRYPT
			run_cmd ./scripts/config --disable AMD_MEM_ENCRYPT_ACTIVE_BY_DEFAULT
			run_cmd ./scripts/config --enable  KVM_AMD_SEV
			run_cmd ./scripts/config --module  CRYPTO_DEV_CCP_DD
			run_cmd ./scripts/config --disable SYSTEM_TRUSTED_KEYS
			run_cmd ./scripts/config --disable SYSTEM_REVOCATION_KEYS
			run_cmd ./scripts/config --disable MODULE_SIG_KEY
                        # Embed SEV_GUEST into the kernel to enable to use /dev/sev-guest from initrd.
			run_cmd ./scripts/config --enable  SEV_GUEST
			run_cmd ./scripts/config --disable IOMMU_DEFAULT_PASSTHROUGH
			run_cmd ./scripts/config --disable PREEMPT_COUNT
			run_cmd ./scripts/config --disable PREEMPTION
			run_cmd ./scripts/config --disable PREEMPT_DYNAMIC
			run_cmd ./scripts/config --disable DEBUG_PREEMPT
			run_cmd ./scripts/config --enable  CGROUP_MISC
			run_cmd ./scripts/config --module  X86_CPUID
			run_cmd ./scripts/config --disable UBSAN

			run_cmd echo $COMMIT >../../source-commit.kernel.$V
		popd >/dev/null

		yes "" | $MAKE olddefconfig

		# Build 
		run_cmd $MAKE >/dev/null

		if [ "$ID" = "debian" ] || [ "$ID_LIKE" = "debian" ]; then
			run_cmd $MAKE bindeb-pkg
		else
			run_cmd $MAKE "RPMOPTS='--define \"_rpmdir .\"'" binrpm-pkg
			run_cmd mv ${V}/x86_64/*.rpm .
		fi
	done

	popd
}

build_install_ovmf()
{
	DEST="$1"

	GCC_VERSION=$(gcc -v 2>&1 | tail -1 | awk '{print $3}')
	GCC_MAJOR=$(echo $GCC_VERSION | awk -F . '{print $1}')
	GCC_MINOR=$(echo $GCC_VERSION | awk -F . '{print $2}')
	if [ "$GCC_MAJOR" == "4" ]; then
		GCCVERS="GCC${GCC_MAJOR}${GCC_MINOR}"
	else
		GCCVERS="GCC5"
	fi

        # Use AmdSevX64 to use measured boot with DKB.
        BUILD_CMD="nice build -q --cmd-len=64436 -DDEBUG_ON_SERIAL_PORT=TRUE -n $(getconf _NPROCESSORS_ONLN) ${GCCVERS:+-t $GCCVERS} -a X64 -p OvmfPkg/AmdSev/AmdSevX64.dsc"

	# initialize git repo, or update existing remote to currently configured one
	if [ -d ovmf ]; then
		pushd ovmf >/dev/null
		if git remote get-url current 2>/dev/null; then
			run_cmd git remote set-url current ${OVMF_GIT_URL}
		else
			run_cmd git remote add current ${OVMF_GIT_URL}
		fi
		popd >/dev/null
	else
		run_cmd git clone --single-branch -b ${OVMF_TAG} ${OVMF_GIT_URL} ovmf
		pushd ovmf >/dev/null
		run_cmd git remote add current ${OVMF_GIT_URL}
		popd >/dev/null
	fi

	pushd ovmf >/dev/null
		run_cmd git fetch current
		run_cmd git checkout -b ${OVMF_TAG} refs/tags/${OVMF_TAG}
		run_cmd git submodule update --init --recursive
                touch OvmfPkg/AmdSev/Grub/grub.efi
		run_cmd make -C BaseTools
		. ./edksetup.sh --reconfig
		run_cmd $BUILD_CMD

		mkdir -p $DEST
		run_cmd cp -f Build/AmdSev/DEBUG_$GCCVERS/FV/OVMF.fd $DEST

		COMMIT=$(git log --format="%h" -1 HEAD)
		run_cmd echo $COMMIT >../source-commit.ovmf
	popd >/dev/null
}

build_install_qemu()
{
	DEST="$1"

	# initialize git repo, or update existing remote to currently configured one
	if [ -d qemu ]; then
		pushd qemu >/dev/null
		if git remote get-url current 2>/dev/null; then
			run_cmd git remote set-url current ${QEMU_GIT_URL}
		else
			run_cmd git remote add current ${QEMU_GIT_URL}
		fi
		popd >/dev/null
	else
		run_cmd git clone --single-branch -b ${QEMU_TAG} ${QEMU_GIT_URL} qemu
		pushd qemu >/dev/null
		run_cmd git remote add current ${QEMU_GIT_URL}
		popd >/dev/null
	fi

	MAKE="make -j $(getconf _NPROCESSORS_ONLN) LOCALVERSION="

	pushd qemu >/dev/null
		run_cmd git fetch current
		run_cmd git checkout -b ${QEMU_TAG} refs/tags/${QEMU_TAG}
		run_cmd ./configure ${QEMU_CONFIGURE_OPTS:-""} --target-list=x86_64-softmmu --prefix=$DEST
		run_cmd $MAKE
		run_cmd $MAKE install

		COMMIT=$(git log --format="%h" -1 HEAD)
		run_cmd echo $COMMIT >../source-commit.qemu
	popd >/dev/null
}
