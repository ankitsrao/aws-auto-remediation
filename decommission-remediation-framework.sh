#!/bin/bash

: '
#SYNOPSIS
    Decommissioning Remediation Framework.
.DESCRIPTION
    This script will remove all the services deployed for the remediation framework.
.NOTES
    Version: 1.0

    # PREREQUISITE
      - Install aws cli
        Link : https://docs.aws.amazon.com/cli/latest/userguide/install-linux-al2017.html
      - Before running this script, you need to delete the associated remediation s3-bucket
        Bucket name is as follows : cn-rem-{environment-prefix}-{account-id-hash}
      - Configure your aws account using the below command:
        aws configure
        Enter the required inputs:
            AWS Access Key ID: Access key of any admin user of the account in consideration.
            AWS Secret Access Key: Secret Access Key of any admin user of the account in consideration
            Default region name: Programmatic region name where you want to deploy the framework (eg: us-east-1)
            Default output format: json  
      - Run this script in any bash shell (linux command prompt)

.EXAMPLE
    Command to execute : bash decommission-remediation-framework.sh [-a <12-digit-account-id>] [-e <environment-prefix>]

.INPUTS
    **Mandatory(-a)Account Id: 12-digit AWS account Id of the account where the remediation framework is deployed
    (-e)Environment prefix: Enter any suitable prefix for your deployment

.OUTPUTS
    None
'

usage() { echo "Usage: $0 [-a <12-digit-account-id>] [-e <environment-prefix>] [-v <1.0>] [-m <region1> -m <region2> ...]" 1>&2; exit 1; }
env="dev"
version="1.0"
while getopts "a:e:m:" o; do
    case "${o}" in
        a)
            awsaccountid=${OPTARG}
            ;;
        e)
            env=${OPTARG}
            ;;
		m) regionlist+=("$OPTARG");;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

Regions=( "us-east-1" "us-east-2" "us-west-1" "us-west-2" "ap-south-1" "ap-northeast-2" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1" "ca-central-1" "eu-central-1" "eu-west-1" "eu-west-2" "eu-west-3" "eu-north-1" "sa-east-1" "ap-east-1" )

#Validating user input for custom regions
selectedregions=" ${regionlist[*]}"                    # add framing blanks
for value in ${Regions[@]}; do
  if [[ $selectedregions =~ " $value " ]] ; then    # use $value as regexp to validate
    customregions+=($value)
  fi
done

if [[ "$awsaccountid" == "" ]] || ! [[ "$awsaccountid" =~ ^[0-9]+$ ]] || [[ ${#awsaccountid} != 12 ]]; then
    usage
fi

aws_region="$(aws configure get region 2>/dev/null)"

acc_sha="$(echo -n "${awsaccountid}" | md5sum | cut -d" " -f1)"

env="$(echo "$env" | tr "[:upper:]" "[:lower:]")"
stack_detail="$(aws cloudformation describe-stacks --stack-name cn-rem-functions-$env-$acc_sha --region $aws_region 2>/dev/null)"
stack_status=$?

echo "Validating environment prefix..."
sleep 5

if [[ $stack_status -ne 0 ]]; then
    echo "Invaild environment prefix. No relevant stack found. Please enter current environment prefix and try to re-run the script again."
    exit 1
fi

echo "Checking if the remediation bucket has been deleted or not...."

s3_detail="$(aws s3api get-bucket-versioning --bucket cn-rem-$env-$acc_sha 2>/dev/null)"
s3_status=$?

echo "Checking if the deployment bucket was correctly deleted... "
sleep 5

if [[ $s3_status -eq 0 ]]; then
    echo "Deployment bucket is still not deleted. Please delete cn-rem-$env-$acc_sha and try to re-run the script again."
    exit 1
fi

echo "Deleting deployment stack..."
#remove termination protection from stack
aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name cn-rem-functions-$env-$acc_sha --region $aws_region
aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name cn-rem-$env-$acc_sha --region $aws_region

#Delete remediation framework stack
aws cloudformation delete-stack --stack-name cn-rem-functions-$env-$acc_sha --region $aws_region
lambda_status=$?

aws cloudformation delete-stack --stack-name cn-rem-$env-$acc_sha --region $aws_region
bucket_status=$?

echo "Deleting Regional Deployments...."

RemediationRegion=( $aws_region )

DeploymentRegion=()
if [[ "$regionlist" -eq "All" ]]; then
	#Remove AWS_Region from all regions
	for Region in "${Regions[@]}"; do
		skip=
		for DefaultRegion in "${RemediationRegion[@]}"; do
			[[ $Region == $DefaultRegion ]] && { skip=1; break; }
		done
		[[ -n $skip ]] || DeploymentRegion+=("$Region")
	done

	declare -a DeploymentRegion
elif [[ "$regionlist" -eq "NA" ]]; then
    #For null pass(Single region)
    echo "End of operation as NA input recieved"
    exit 1
else
	#Remove AWS_Region from custom region list
	for Region in "${customregions[@]}"; do
		skip=
		for DefaultRegion in "${RemediationRegion[@]}"; do
			[[ $Region == $DefaultRegion ]] && { skip=1; break; }
		done
		[[ -n $skip ]] || DeploymentRegion+=("$Region")
	done

	declare -a DeploymentRegion
fi

for i in "${DeploymentRegion[@]}";
do
    #remove termination protection
    aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name cn-rem-$env-$i-$acc_sha --region $i
    #delete stack from other regions
    aws cloudformation delete-stack --stack-name cn-rem-$env-$i-$acc_sha --region $i
done

if [[ $lambda_status -eq 0 ]]  && [[ $bucket_status -eq 0 ]]; then
    echo "Successfully deleted deployment stack!"
else
    echo "Something went wrong! Please contact Cloudneeti support!"
fi