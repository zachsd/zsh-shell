alias k = ^kubectl
# Common CLI aliases. Nushell builtins (ls, ps, open, etc.) retain structured output.
alias ll = ^eza -lah --icons --group-directories-first --git
alias la = ^eza -a --icons
alias lt = ^eza --tree --icons -L 3
alias batp = ^bat --style=plain --paging=never
alias batf = ^bat --style=full
alias tf = ^terraform
alias tfi = ^terraform init
alias tfiu = ^terraform init -upgrade
alias tfp = ^terraform plan
alias tfa = ^terraform apply
alias tfaa = ^terraform apply -auto-approve
alias tfd = ^terraform destroy
alias tfdaa = ^terraform destroy -auto-approve
alias tfw = ^terraform workspace
alias tfwl = ^terraform workspace list
alias tfws = ^terraform workspace select
alias tff = ^terraform fmt -recursive
alias tfv = ^terraform validate
alias tfs = ^terraform state
alias tfsl = ^terraform state list
alias tfss = ^terraform state show
alias tfi-lock = ^terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64
alias tg = ^terragrunt
alias tgp = ^terragrunt plan
alias tga = ^terragrunt apply
alias tgaa = ^terragrunt apply --auto-approve
alias tgd = ^terragrunt destroy
alias tgra = ^terragrunt run-all apply
alias tgraa = ^terragrunt run-all apply --auto-approve
alias tgrp = ^terragrunt run-all plan
alias tgrd = ^terragrunt run-all destroy
alias tgv = ^terragrunt validate
alias tgf = ^terragrunt hclfmt
alias awsprofiles = ^aws configure list-profiles
alias awss3ls = ^aws s3 ls
alias awsecr = ^aws ecr describe-repositories --output table
alias azlist = ^az account list --output table
alias azswitch = ^az account set --subscription
alias azlogin = ^az login
alias azrg = ^az group list --output table
alias azvm = ^az vm list --output table
alias azaks = ^az aks list --output table
alias kga = ^kubectl get all -A
alias kgp = ^kubectl get pods
alias kgpa = ^kubectl get pods -A -o wide
alias kgn = ^kubectl get nodes -o wide
alias kgs = ^kubectl get svc -A
alias kgi = ^kubectl get ingress -A
alias kgd = ^kubectl get deployments -A
alias kgcm = ^kubectl get configmap -A
alias kgsec = ^kubectl get secrets -A
alias kgpv = ^kubectl get pv,pvc -A
alias kd = ^kubectl describe
alias kdp = ^kubectl describe pod
alias kdn = ^kubectl describe node
alias kl = ^kubectl logs
alias klf = ^kubectl logs -f
alias klt = ^kubectl logs --tail=100
alias ke = ^kubectl exec -it
alias kaf = ^kubectl apply -f
alias kdf = ^kubectl delete -f
alias kdel = ^kubectl delete
alias kctxl = ^kubectl config get-contexts
alias kns = ^kubens
alias kctx = ^kubectx
alias k9 = ^k9s
alias ocp = ^oc
alias ocwho = ^oc whoami
alias ocproject = ^oc project
alias ocprojects = ^oc projects
alias ocget = ^oc get all
alias oclogs = ^oc logs -f
alias oclogin = ^oc login
alias h = ^helm
alias hl = ^helm list -A
alias hr = ^helm repo
alias hrl = ^helm repo list
alias hru = ^helm repo update
alias hrs = ^helm repo search
alias hi = ^helm install
alias hup = ^helm upgrade --install
alias hun = ^helm uninstall
alias hst = ^helm status
alias hh = ^helm history
alias hd = ^helm diff
alias hvals = ^helm show values
alias htemplate = ^helm template
alias d = ^docker
alias dps = ^docker ps -a
alias dim = ^docker images
alias dex = ^docker exec -it
alias dlogs = ^docker logs -f
alias dstop = ^docker stop
alias drm = ^docker rm
alias drmi = ^docker rmi
alias dprune = ^docker system prune -af --volumes
alias dc = ^docker-compose
alias dcu = ^docker-compose up -d
alias dcd = ^docker-compose down
alias dcl = ^docker-compose logs -f
alias gs = ^git status
alias ga = ^git add
alias gaa = ^git add -A
alias gc = ^git commit
alias gcm = ^git commit -m
alias gca = ^git commit --amend --no-edit
alias gp = ^git push
alias gpf = ^git push --force-with-lease
alias gpl = ^git pull
alias gplr = ^git pull --rebase
alias gco = ^git checkout
alias gcob = ^git checkout -b
alias gb = ^git branch
alias gba = ^git branch -a
alias gbd = ^git branch -d
alias glog = ^git log --oneline --graph --decorate --all
alias gd = ^git diff
alias gds = ^git diff --staged
alias gst = ^git stash
alias gstp = ^git stash pop
alias gstl = ^git stash list
alias gclean = ^git clean -fdx
alias gtag = ^git tag --sort=-version:refname

def --env mkcd [directory: path] { mkdir $directory; cd $directory }
def awswho [] { ^aws sts get-caller-identity | from json }
def --env awsprofile [profile?: string] {
    let chosen = if $profile != null { $profile } else { ^aws configure list-profiles | ^fzf --prompt 'AWS profile: ' | str trim }
    if $chosen != '' { $env.AWS_PROFILE = $chosen }
}
def --env awsregion [region: string] { $env.AWS_DEFAULT_REGION = $region }
def eksconfig [cluster: string, region: string = 'us-east-1'] { ^aws eks update-kubeconfig --name $cluster --region $region }
def aksconfig [group: string, cluster: string] { ^az aks get-credentials --resource-group $group --name $cluster }
def kswitch [] {
    let ctx = (^kubectl config get-contexts -o name | ^fzf --prompt 'Kube context: ' | str trim)
    if $ctx != '' { ^kubectl config use-context $ctx }
}
def kpf [resource: string, ports: string = '8080:8080'] { ^kubectl port-forward $resource $ports }
def b64enc [text: string] { $text | encode base64 }
def b64dec [text: string] { $text | decode base64 | decode utf-8 }
def serve [port: int = 8000] { ^python3 -m http.server $port }
