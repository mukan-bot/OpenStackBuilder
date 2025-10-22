@echo off
REM Windows batch script to set executable permissions on shell scripts
REM Run this script on Windows before copying scripts to Linux

echo Setting executable permissions on shell scripts...

if exist "deploy_controller.sh" (
    echo Setting permissions for deploy_controller.sh
    git update-index --chmod=+x deploy_controller.sh
)

if exist "deploy_compute.sh" (
    echo Setting permissions for deploy_compute.sh
    git update-index --chmod=+x deploy_compute.sh
)

if exist "health_check.sh" (
    echo Setting permissions for health_check.sh
    git update-index --chmod=+x health_check.sh
)

if exist "cleanup.sh" (
    echo Setting permissions for cleanup.sh
    git update-index --chmod=+x cleanup.sh
)

echo.
echo All shell scripts have been marked as executable.
echo After copying to Linux, you can also run:
echo chmod +x *.sh
echo.
pause