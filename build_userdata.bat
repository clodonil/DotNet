echo "Setup enviromemnt variables"
SET COBCPY=c:\build\copybook
SET COBDIR=C:\Program Files (x86)\Micro Focus\Enterprise Developer\;
SET COBREG_64_PARSED=True
SET INCLUDE=C:\Program Files (x86)\Micro Focus\Enterprise Developer\include;
SET JAVA_HOME=C:\Program Files (x86)\Micro Focus\Enterprise Developer\AdoptOpenJDK
SET LIB=C:\Program Files (x86)\Micro Focus\Enterprise Developer\lib64\;
SET MFDBFH_SCRIPT_DIR=C:\Program Files (x86)\Micro Focus\Enterprise Developer\etc\mfdbfh\scripts
SET MFPLI_PRODUCT_DIR=C:\Program Files (x86)\Micro Focus\Enterprise Developer\
SET MFTRACE_ANNOTATIONS=C:\Program Files (x86)\Micro Focus\Enterprise Developer\etc\mftrace\annotations
SET MFTRACE_LOGS=C:\ProgramData\Micro Focus\Enterprise Developer\5.0\mftrace\logs
SET Path=C:\Program Files (x86)\Micro Focus\Enterprise Developer\bin64\;C:\Program Files (x86)\Micro Focus\Enterprise Developer\binn64\;C:\Program Files (x86)\Micro Focus\Enterprise Developer\bin\;C:\Program Files (x86)\Micro Focus\Enterprise Developer\AdoptOpenJDK\bin;C:\Program Files (x86)\Micro Focus\Enterprise Developer\AdoptRedis;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0\;C:\Program Files\Amazon\cfn-bootstrap\;;C:\Program Files\Docker;C:\Program Files\Amazon\AWSCLI\bin\;C:\Users\Administrator\AppData\Local\Microsoft\WindowsApps;
SET PATHEXT=.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC
SET TXDIR=C:\Program Files (x86)\Micro Focus\Enterprise Developer\
SET BUILD_BUCKET=%1
SET SOURCE_FOLDER=%2

cd \
echo "Cleanup work directory"
if exist log (rmdir log /s /q)
if exist build (rmdir build /s /q)

echo "Downloading artifact zip"
mkdir log
aws s3 cp s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/artifacts.zip \artifacts.zip --quiet
PowerShell Expand-Archive -Path \artifacts.zip -DestinationPath \
rename bankTest build
cd build\cbl
aws s3 cp s3://%BUILD_BUCKET%/diretivas_compilacao.dir diretivas_compilacao.dir --quiet

echo "Building cobol files"
For %%A in (*.cbl) do cobol %%A,,,preprocess(EXCI) USE(diretivas_compilacao.dir); > c:\log\%%A-cobol.log 2> c:\log\%%A-cobol.err

echo "Building dll files"
For %%A in (*.obj) do cbllink -d %%A > c:\log\%%A-cbllink.log 2> c:\log\%%A-cbllink.err

echo "Wait 5 seconds to work with compiled files"
ping -n 5 127.0.0.1 >nul

echo "Remove 0 bytes files from log directory"
cd \log
for /r %%F in (*) do if %%~zF==0 del "%%F"

echo "Coping log files to bucket"
cd \
aws s3 cp log s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/log --recursive --acl bucket-owner-full-control --quiet

echo "Querying ec2 instance information"
for /f "usebackq delims=" %%x in (`powershell Invoke-RestMethod -uri http://169.254.169.254/latest/meta-data/instance-id`) do set INSTANCE_ID=%%x
for /f "usebackq delims=" %%x in (`powershell Invoke-RestMethod -uri http://169.254.169.254/latest/meta-data/local-ipv4`) do set LOCAL_IPV4=%%x

if exist \log\*.err (
    echo "Sending fail information to the pipeline"
    aws codepipeline put-job-failure-result --job-id %2 --failure-details type=JobFailed,message="Build process failed. Check bucket for details: s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/log" --region us-west-2

    echo "Sending signal to finish the process with fail"
    aws sns publish --topic-arn %3 --subject "build completed with a result of 'failed'" --message s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/log --message-attributes ec2_instance={DataType=String,StringValue=%INSTANCE_ID%} --region us-west-2

    echo "Removing control tag from ec2"
    aws ec2 delete-tags --resources %INSTANCE_ID% --tags Key=job_id,Value=%SOURCE_FOLDER%

    echo "Coping process log file to bucket"
    aws s3 cp %SystemRoot%\Temp\process.log s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/process.log --acl bucket-owner-full-control --quiet

    echo "Sttoping ec2 instance"
    shutdown.exe /s /t 00
) else (
    echo "Sending success information to the pipeline"
    aws codepipeline put-job-success-result --job-id %2 --region us-west-2

    echo "Coping dll files to bucket"
    aws s3 cp \build\cbl s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/dll_files/ --acl bucket-owner-full-control --recursive --quiet --exclude "*" --include "*.dll"

    echo "Sending signal to finish the process with success"
    aws sns publish --topic-arn %3 --subject "build completed with a result of 'success'" --message "PrivateIpAddress: %LOCAL_IPV4%" --message-attributes ec2_instance={DataType=String,StringValue=%INSTANCE_ID%} --region us-west-2    

    echo "Coping process log file to bucket"
    aws s3 cp %SystemRoot%\Temp\process.log s3://%BUILD_BUCKET%/%SOURCE_FOLDER%/process.log --acl bucket-owner-full-control --quiet
)