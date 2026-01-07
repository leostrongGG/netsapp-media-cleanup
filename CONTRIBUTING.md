# Contribuindo para o Netsapp Media Cleanup Manager

Obrigado por considerar contribuir! 🎉

## Como Contribuir

1. **Fork** o projeto
2. Crie uma **branch** para sua feature (`git checkout -b feature/MinhaFeature`)
3. **Commit** suas mudanças (`git commit -m 'Add: descrição da feature'`)
4. **Push** para a branch (`git push origin feature/MinhaFeature`)
5. Abra um **Pull Request**

## Padrões de Commit

Use prefixos claros:
- `Add:` nova funcionalidade
- `Fix:` correção de bug
- `Docs:` documentação
- `Refactor:` refatoração sem mudança de comportamento
- `Test:` adicionar testes

## Reportar Bugs

Ao reportar bugs, inclua:
- Versão do sistema operacional
- Versão do Docker
- Logs relevantes (`runs/run_*/run.log`)
- Passos para reproduzir

## Sugestões de Features

Abra uma issue descrevendo:
- Problema que resolve
- Como funcionaria
- Exemplos de uso

## Testes

Antes de enviar PR:
1. Teste em ambiente não-produção
2. Execute dry-run: `sudo ./run_dry.sh --days 5`
3. Valide os scripts gerados
4. Teste restauração se aplicável

## Dúvidas?

Abra uma issue ou discussion no GitHub!
